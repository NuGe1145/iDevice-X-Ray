import XCTest
@testable import iDeviceXRay

/// 传感器层的纯函数测试。这些逻辑决定报告里每个数字是真是假，
/// 比 UI 更需要守住。
final class SensorMathTests: XCTestCase {

    // MARK: - SMC 键

    func testSMCKeyFromLocation() {
        // 0x49513075 = "IQ0u"
        XCTAssertEqual(HIDSensorProbe.smcKey(0x4951_3075), "IQ0u")
        XCTAssertEqual(HIDSensorProbe.smcKey(0x5451_306A), "TQ0j")
    }

    func testSMCKeyRejectsNonPrintable() {
        XCTAssertEqual(HIDSensorProbe.smcKey(0), "")
        XCTAssertEqual(HIDSensorProbe.smcKey(0x0000_0012), "")
    }

    // MARK: - 重复 service 合并

    func testDuplicateKeyIsAveragedNotSummed() {
        let raw = [
            RawSensor(name: "gas gauge battery", key: "TB0T", index: 0, kind: .temperature, value: 30),
            RawSensor(name: "gas gauge battery", key: "TB0T", index: 1, kind: .temperature, value: 40)
        ]
        let result = SensorMath.merge(raw)

        XCTAssertEqual(result.sensors.count, 1)
        XCTAssertEqual(result.sensors[0].value, 35, accuracy: 0.001)
        XCTAssertEqual(result.sensors[0].copies, 2)
    }

    func testDifferentKeysStaySeparate() {
        let raw = [
            RawSensor(name: "PMU tdie1", key: "TP1b", index: 0, kind: .temperature, value: 48),
            RawSensor(name: "PMU tdie2", key: "TP1l", index: 1, kind: .temperature, value: 51)
        ]
        let result = SensorMath.merge(raw)

        XCTAssertEqual(result.sensors.count, 2)
        XCTAssertEqual(result.sensors.map(\.key).sorted(), ["TP1b", "TP1l"])
    }

    // MARK: - 不可能的值

    func testSentinelTemperatureIsDropped() {
        let raw = [RawSensor(name: "Charger TQ0j", key: "TQ0j", index: 0, kind: .temperature, value: -9_199.4)]
        let result = SensorMath.merge(raw)

        XCTAssertTrue(result.sensors.isEmpty)
        XCTAssertEqual(result.dropped, 1)
    }

    func testNonFiniteValueIsSkipped() {
        let raw = [RawSensor(name: "battery", key: "TB0T", index: 0, kind: .temperature, value: .nan)]
        let result = SensorMath.merge(raw)

        XCTAssertTrue(result.sensors.isEmpty)
        XCTAssertEqual(result.dropped, 0, "NaN 是「没读数」，不是「不合理值」")
    }

    func testVoltageIsNotRangeChecked() {
        let raw = [RawSensor(name: "Charger VQ0u", key: "VQ0u", index: 0, kind: .voltage, value: 9.2)]
        let result = SensorMath.merge(raw)

        XCTAssertEqual(result.sensors.count, 1)
        XCTAssertEqual(result.sensors[0].value, 9.2, accuracy: 0.001)
    }

    // MARK: - 分区归类

    func testZoneByKeyword() {
        XCTAssertEqual(ThermalZone.classify(name: "gas gauge battery", key: "TB0T"), .battery)
        XCTAssertEqual(ThermalZone.classify(name: "Charger TQ0j", key: "TQ0j"), .charger)
        XCTAssertEqual(ThermalZone.classify(name: "PMU tdie3", key: "TP1b"), .soc)
        XCTAssertEqual(ThermalZone.classify(name: "NAND die", key: "TN0d"), .storage)
    }

    func testWirelessWinsOverCharger() {
        // "wireless charger" 同时含 charger 关键词，必须先命中无线
        XCTAssertEqual(ThermalZone.classify(name: "wireless charger coil", key: "TR0x"), .wireless)
    }

    func testUnknownNameFallsBackToOther() {
        XCTAssertEqual(ThermalZone.classify(name: "sensor 17", key: "TZ99"), .other)
    }

    // MARK: - 最热测点

    func testHottestWithinZones() {
        var snapshot = EnergySnapshot.empty
        snapshot.temperatures = [
            SensorReading(name: "battery", key: "TB0T", zone: .battery, kind: .temperature, value: 33, copies: 1),
            SensorReading(name: "Charger TQ0j", key: "TQ0j", zone: .charger, kind: .temperature, value: 44, copies: 1),
            SensorReading(name: "PMU tdie1", key: "TP1b", zone: .soc, kind: .temperature, value: 52, copies: 1)
        ]

        XCTAssertEqual(snapshot.hottest(in: [.battery])?.value, 33)
        XCTAssertEqual(snapshot.hottest(in: [.charger, .soc])?.value, 52)
        XCTAssertNil(snapshot.hottest(in: [.storage]))
    }
}
