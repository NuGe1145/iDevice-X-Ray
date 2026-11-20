import XCTest
import SQLite3
@testable import iDeviceXRay

/// 用合成的 SQLite 库验证解析逻辑。
/// 真机样本的表结构还没拿到，所以这里测的是「能不能按列名认出角色」这件事本身，
/// 而不是某台设备的具体数值。
final class PowerlogTests: XCTestCase {

    private var databaseURL: URL!

    override func setUpWithError() throws {
        databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("powerlog-\(UUID().uuidString).PLSQL")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: databaseURL)
    }

    // MARK: - 建库

    @discardableResult
    private func makeDatabase(_ statements: [String]) throws -> URL {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &handle), SQLITE_OK)
        guard let db = handle else {
            XCTFail("无法创建测试数据库")
            throw XCTSkip("sqlite 不可用")
        }
        defer { sqlite3_close(db) }

        for sql in statements {
            var error: UnsafeMutablePointer<CChar>?
            let result = sqlite3_exec(db, sql, nil, nil, &error)
            if result != SQLITE_OK {
                let message = error.map { String(cString: $0) } ?? "未知"
                sqlite3_free(error)
                XCTFail("SQL 执行失败：\(message)")
            }
        }
        return databaseURL
    }

    // MARK: - 主流程

    func testReadsCycleCountCapacityAndTemperature() throws {
        let now = Date().timeIntervalSince1970
        let sql = """
        CREATE TABLE PLBatteryAgent_EventBackward_Battery (
            id INTEGER PRIMARY KEY,
            timestamp REAL,
            CycleCount INTEGER,
            DesignCapacity INTEGER,
            AppleRawMaxCapacity INTEGER,
            AppleRawCurrentCapacity INTEGER,
            Temperature REAL,
            Voltage REAL
        );
        INSERT INTO PLBatteryAgent_EventBackward_Battery VALUES (1, \(now - 172_800), 250, 4500, 4400, 2200, 3050, 4050);
        INSERT INTO PLBatteryAgent_EventBackward_Battery VALUES (2, \(now - 86_400), 254, 4500, 4350, 2100, 3120, 4010);
        INSERT INTO PLBatteryAgent_EventBackward_Battery VALUES (3, \(now), 258, 4500, 4300, 2000, 3080, 3980);
        """
        let url = try makeDatabase([sql])

        let outcome = PowerlogReader.read(url: url)
        let summary = try XCTUnwrap(outcome.summary)

        XCTAssertEqual(summary.cycleCount, 258)
        XCTAssertEqual(summary.designCapacity, 4500)
        XCTAssertEqual(summary.maxCapacity, 4300)
        XCTAssertEqual(summary.rowCount, 3)
        XCTAssertEqual(summary.capacityUnit, "%")
        XCTAssertEqual(summary.capacitySeries.count, 3)

        let health = try XCTUnwrap(summary.healthPercent)
        XCTAssertEqual(health, 95.5, accuracy: 0.2)

        // 3050 / 3080 是 0.1°C 写法，应还原成 30.5 与 30.8 附近
        let temperature = try XCTUnwrap(summary.latestTemperature)
        XCTAssertEqual(temperature, 30.8, accuracy: 0.2)

        let voltage = try XCTUnwrap(summary.latestVoltage)
        XCTAssertEqual(voltage, 3.98, accuracy: 0.02)

        XCTAssertEqual(summary.extraction["battery.cycleCount"], "258 次")
        XCTAssertEqual(summary.extraction["battery.health"], "96%")
    }

    func testCapacitySeriesIsChronological() throws {
        let now = Date().timeIntervalSince1970
        // 倒序写入，验证输出仍按时间升序
        let sql = """
        CREATE TABLE PLBatteryAgent_EventBackward_Battery (
            id INTEGER PRIMARY KEY, timestamp REAL, CycleCount INTEGER,
            DesignCapacity INTEGER, AppleRawMaxCapacity INTEGER
        );
        INSERT INTO PLBatteryAgent_EventBackward_Battery VALUES (1, \(now), 300, 4000, 3600);
        INSERT INTO PLBatteryAgent_EventBackward_Battery VALUES (2, \(now - 3600), 299, 4000, 3900);
        INSERT INTO PLBatteryAgent_EventBackward_Battery VALUES (3, \(now - 7200), 298, 4000, 3950);
        """
        let url = try makeDatabase([sql])
        let summary = try XCTUnwrap(PowerlogReader.read(url: url).summary)

        let times = summary.capacitySeries.map(\.time)
        XCTAssertEqual(times, times.sorted())
        XCTAssertEqual(summary.capacitySeries.first?.value ?? 0, 98.75, accuracy: 0.5)
        XCTAssertEqual(summary.capacitySeries.last?.value ?? 0, 90, accuracy: 0.5)
    }

    func testPicksBatteryTableOverUnrelatedTables() throws {
        let now = Date().timeIntervalSince1970
        let sql = """
        CREATE TABLE PLBatteryAgent_EventPoint_PluggedIn (id INTEGER PRIMARY KEY, timestamp REAL, PortType INTEGER);
        CREATE TABLE PLBatteryAgent_EventBackward_Battery (
            id INTEGER PRIMARY KEY, timestamp REAL, CycleCount INTEGER, DesignCapacity INTEGER, AppleRawMaxCapacity INTEGER
        );
        INSERT INTO PLBatteryAgent_EventBackward_Battery VALUES (1, \(now), 120, 3200, 3000);
        """
        let url = try makeDatabase([sql])
        let outcome = PowerlogReader.read(url: url)
        let summary = try XCTUnwrap(outcome.summary)

        XCTAssertEqual(summary.table, "PLBatteryAgent_EventBackward_Battery")
        XCTAssertEqual(summary.candidateTables, 2)
        XCTAssertEqual(summary.cycleCount, 120)
    }

    func testTableWithoutTimestampIsRejected() throws {
        let sql = """
        CREATE TABLE PLBatteryAgent_EventBackward_Battery (id INTEGER PRIMARY KEY, CycleCount INTEGER);
        INSERT INTO PLBatteryAgent_EventBackward_Battery VALUES (1, 42);
        """
        let url = try makeDatabase([sql])
        let outcome = PowerlogReader.read(url: url)

        XCTAssertNil(outcome.summary)
        XCTAssertFalse(outcome.notes.isEmpty)
    }

    func testNonPowerlogDatabaseReturnsNote() throws {
        let url = try makeDatabase(["CREATE TABLE Something (id INTEGER PRIMARY KEY, value REAL);"])

        let outcome = PowerlogReader.read(url: url)
        XCTAssertNil(outcome.summary)
        XCTAssertTrue(outcome.notes.contains { $0.contains("PLBatteryAgent") })
    }

    func testMissingFileDoesNotCrash() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("not-there-\(UUID()).PLSQL")
        let outcome = PowerlogReader.read(url: url)
        XCTAssertNil(outcome.summary)
        XCTAssertFalse(outcome.notes.isEmpty)
    }

    // MARK: - 单位换算

    func testDecodeDateHandlesSecondsMillisecondsAndAppleEpoch() {
        let seconds: Double = 1_731_000_000
        XCTAssertEqual(PowerlogReader.decodeDate(seconds)?.timeIntervalSince1970 ?? 0, seconds, accuracy: 1)
        XCTAssertEqual(PowerlogReader.decodeDate(seconds * 1000)?.timeIntervalSince1970 ?? 0, seconds, accuracy: 1)

        let appleEpoch = seconds - 978_307_200
        XCTAssertEqual(PowerlogReader.decodeDate(appleEpoch)?.timeIntervalSince1970 ?? 0, seconds, accuracy: 1)

        XCTAssertNil(PowerlogReader.decodeDate(0))
        XCTAssertNil(PowerlogReader.decodeDate(1))
    }

    func testDecodeCelsiusHandlesFourScales() {
        // 已经是 °C
        XCTAssertEqual(PowerlogReader.decodeCelsius(32) ?? 0, 32, accuracy: 0.01)
        // 0.1 °C
        XCTAssertEqual(PowerlogReader.decodeCelsius(305) ?? 0, 30.5, accuracy: 0.01)
        // 0.01 °C
        XCTAssertEqual(PowerlogReader.decodeCelsius(3012) ?? 0, 30.12, accuracy: 0.01)
        // 0.1 K（303.15 K = 30 °C）
        XCTAssertEqual(PowerlogReader.decodeCelsius(3031) ?? 0, 30.31, accuracy: 0.05)
        // 明显不可能的哨兵值
        XCTAssertNil(PowerlogReader.decodeCelsius(-91_994))
    }

    func testDecodeVoltsRejectsImplausible() {
        XCTAssertEqual(PowerlogReader.decodeVolts(4050) ?? 0, 4.05, accuracy: 0.01)
        XCTAssertEqual(PowerlogReader.decodeVolts(4.05) ?? 0, 4.05, accuracy: 0.01)
        XCTAssertNil(PowerlogReader.decodeVolts(20_000))
        XCTAssertNil(PowerlogReader.decodeVolts(0.3))
    }
}
