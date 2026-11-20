import Foundation
import XCTest
@testable import iDeviceXRay

final class ReportModelTests: XCTestCase {

    func testUnavailableFieldShowsDash() {
        let field = ReportField.unavailable(key: "display.vendor", title: "面板供应商", reason: "系统不暴露")
        XCTAssertEqual(field.displayValue, "—")
        XCTAssertEqual(field.confidence, .unavailable)
    }

    func testDisplayValueAppendsUnit() {
        let field = ReportField(
            key: "battery.level",
            title: "当前电量",
            value: "85",
            unit: "%",
            source: .live,
            confidence: .verified
        )
        XCTAssertEqual(field.displayValue, "85%")
    }

    func testCompletenessScore() {
        let fields = [
            ReportField(key: "a", title: "A", value: "1", source: .live, confidence: .verified),
            ReportField(key: "b", title: "B", value: "2", source: .live, confidence: .verified),
            ReportField.unavailable(key: "c", title: "C", reason: "n/a")
        ]
        let section = ReportSection(key: "s", title: "S", symbol: "gear", accentHex: 0xFFFFFF, fields: fields)
        let report = ScanReport(
            mode: .standard,
            deviceName: "iPhone 16 Pro",
            identifier: "iPhone17,1",
            osVersion: "26.0",
            sections: [section]
        )

        XCTAssertEqual(report.totalCount, 3)
        XCTAssertEqual(report.readableCount, 2)
        XCTAssertEqual(report.verifiedCount, 2)
        XCTAssertEqual(report.completenessScore, 67)
    }

    func testDataFusionOverridesUnavailableField() {
        let fields = [
            ReportField.unavailable(key: "battery.cycleCount", title: "循环次数", reason: "需导入档案")
        ]
        let section = ReportSection(key: "battery", title: "电池", symbol: "battery", accentHex: 0x34D399, fields: fields)
        let deep = DeepScanResult(
            fileName: "sysdiagnose.tar.gz",
            fileSizeBytes: 1024,
            entriesScanned: 10,
            matchedFiles: ["ioreg.txt"],
            extraction: ["battery.cycleCount": "258 次"],
            warnings: [],
            durationSeconds: 0.4
        )

        let merged = DataFusion.merge(sections: [section], deep: deep)
        let field = merged[0].fields[0]

        XCTAssertEqual(field.displayValue, "258 次")
        XCTAssertEqual(field.source, .sysdiagnose)
        XCTAssertEqual(field.confidence, .high)
    }
}

final class TarScannerTests: XCTestCase {

    func testScannerCapturesMatchingEntry() {
        let scanner = TarScanner(keywords: ["battery"])
        let content = #""CycleCount" = 258"#

        scanner.feed(makeEntry(name: "logs/battery.log", content: content))
        scanner.feed(makeEntry(name: "logs/unrelated.txt", content: "nothing here"))
        scanner.finish()

        XCTAssertEqual(scanner.entriesScanned, 2)
        XCTAssertEqual(scanner.matchedFiles.count, 1)
        XCTAssertEqual(scanner.captured.first?.name, "logs/battery.log")

        let text = String(decoding: scanner.captured.first?.data ?? Data(), as: UTF8.self)
        XCTAssertTrue(text.contains("CycleCount"))
    }

    func testParserExtractsCycleCount() {
        var outcome = DeepParser.Outcome()
        BatteryLogParser.parse(text: #""CycleCount" = 258"#, fileName: "ioreg.txt", into: &outcome)
        XCTAssertEqual(outcome.values["battery.cycleCount"], "258 次")
    }

    func testParserComputesHealth() {
        var outcome = DeepParser.Outcome()
        let text = #""DesignCapacity" = 3274 "AppleRawMaxCapacity" = 3208"#
        BatteryLogParser.parse(text: text, fileName: "ioreg.txt", into: &outcome)
        XCTAssertEqual(outcome.values["battery.health"], "98%")
    }

    func testInvalidGzipHeaderThrows() {
        let decoder = try? GzipStreamDecoder()
        XCTAssertNotNil(decoder)
        XCTAssertThrowsError(try decoder?.write(Data(repeating: 0x00, count: 32)))
    }

    /// 真机包里有大量 PaxHeader / ._ 条目，命名同样带 battery/powerlog，
    /// 但内容是打包元数据。把它们算进命中列表只会制造噪音。
    func testIgnoresPaxHeaderAndAppleDouble() {
        let scanner = TarScanner(keywords: ["battery"])
        scanner.feed(makeEntry(name: "logs/BatteryUIPlist/PaxHeader/BatteryUI.plist", content: "x"))
        scanner.feed(makeEntry(name: "logs/BatteryUIPlist/._BatteryUI.plist", content: "x"))
        scanner.feed(makeEntry(name: "logs/BatteryUIPlist/BatteryUI.plist", content: "y"))
        scanner.finish()

        XCTAssertEqual(scanner.matchedFiles, ["logs/BatteryUIPlist/BatteryUI.plist"])
    }

    /// iOS 26/27 主库改名成 powerlog_<date>_<hex>.PLSQL，
    /// 只认 CurrentPowerlog.PLSQL 会整包导进来也读不到循环次数。
    func testSpillPlanAcceptsNewPowerlogName() {
        let name = "sysdiagnose_2026.11.20/logs/powerlogs/powerlog_2026-11-20_09-08_908E6B0B.PLSQL"
        XCTAssertTrue(DeepScanService.shouldSpillPowerlog(name: name, size: 180_000_000))
        XCTAssertTrue(DeepScanService.shouldSpillPowerlog(
            name: "logs/powerlogs/CurrentPowerlog.PLSQL", size: 120_000_000
        ))

        // PaxHeader 里的同名条目只有几十字节，不能当主库落盘
        XCTAssertFalse(DeepScanService.shouldSpillPowerlog(
            name: "logs/powerlogs/PaxHeader/powerlog_2026-11-20_09-08_908E6B0B.PLSQL", size: 30
        ))
        // 扩展电源日志是另一种库，先交给别的路径
        XCTAssertFalse(DeepScanService.shouldSpillPowerlog(
            name: "logs/powerlogs/log_2026-11-20_09-08_0C6D3D19.EPSQL", size: 180_000_000
        ))
    }

    /// BatteryUIPlist 是二进制 plist，按 UTF-8 解码是乱码，正则永远匹配不上。
    func testParsesBinaryPlistBatteryFields() throws {
        let dict: [String: Any] = [
            "CycleCount": 258,
            "DesignCapacity": 3274,
            "AppleRawMaxCapacity": 3208
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: dict,
            format: .binary,
            options: 0
        )
        XCTAssertTrue(data.starts(with: Data("bplist00".utf8)))

        let outcome = DeepParser.parse(files: [("logs/BatteryUIPlist/BatteryUI.plist", data)])
        XCTAssertEqual(outcome.values["battery.cycleCount"], "258 次")
        XCTAssertEqual(outcome.values["battery.health"], "98%")
    }

    // MARK: - Helpers

    private func makeEntry(name: String, content: String) -> Data {
        var header = [UInt8](repeating: 0, count: 512)

        let nameBytes = Array(name.utf8)
        for (index, byte) in nameBytes.enumerated() where index < 100 {
            header[index] = byte
        }

        let sizeString = String(format: "%011o", content.utf8.count)
        let sizeBytes = Array(sizeString.utf8)
        for (index, byte) in sizeBytes.enumerated() where index < 11 {
            header[124 + index] = byte
        }

        header[156] = 0x30 // '0'

        var data = Data(header)
        data.append(contentsOf: Array(content.utf8))
        let padding = (512 - content.utf8.count % 512) % 512
        data.append(contentsOf: [UInt8](repeating: 0, count: padding))
        return data
    }
}
