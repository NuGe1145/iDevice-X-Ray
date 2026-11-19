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
