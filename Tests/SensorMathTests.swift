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

    // MARK: - 电池端通道解析

    /// iPad Air 5 上 `IQ0B` 存在但恒为 0.00 A，真实电流在另一条电池轨道上。
    /// 只认固定键会一直显示 0，必须让非零通道优先。
    func testBatteryCurrentPrefersLiveRailOverDeadKey() {
        var snapshot = EnergySnapshot.empty
        snapshot.currents = [
            SensorReading(name: "battery charge current", key: "IQ0B", zone: .battery, kind: .current, value: 0, copies: 1),
            SensorReading(name: "battery current", key: "B0AC", zone: .battery, kind: .current, value: 1.42, copies: 1),
            SensorReading(name: "USB input current", key: "IQ0u", zone: .charger, kind: .current, value: 0.43, copies: 1)
        ]

        let rail = snapshot.batteryCurrentRail()
        XCTAssertEqual(rail?.value ?? 0, 1.42, accuracy: 0.01)
        XCTAssertEqual(rail?.source.contains("B0AC"), true)
    }

    /// 系统电源描述上报的值最权威：跨机型一致，不受 SMC 键改名影响。
    func testBatteryCurrentPrefersSystemReportedValue() {
        var snapshot = EnergySnapshot.empty
        snapshot.power.reportedCurrentAmps = -0.62
        snapshot.currents = [
            SensorReading(name: "battery current", key: "IQ0B", zone: .battery, kind: .current, value: 0, copies: 1)
        ]

        let rail = snapshot.batteryCurrentRail()
        XCTAssertEqual(rail?.value ?? 0, -0.62, accuracy: 0.001)
        XCTAssertEqual(rail?.isSystemReported, true)
    }

    /// 全为零不等于「电流是 0」，是没有读数。宁可返回 nil 让界面显示「—」。
    func testBatteryCurrentIsNilWhenEveryRailIsZero() {
        var snapshot = EnergySnapshot.empty
        snapshot.currents = [
            SensorReading(name: "battery current", key: "IQ0B", zone: .battery, kind: .current, value: 0, copies: 1)
        ]
        XCTAssertNil(snapshot.batteryCurrentRail())
    }

    func testBatteryVoltageFallsBackToBatteryZone() {
        var snapshot = EnergySnapshot.empty
        snapshot.voltages = [
            SensorReading(name: "battery voltage", key: "ZZ99", zone: .battery, kind: .voltage, value: 4.22, copies: 1)
        ]
        XCTAssertEqual(snapshot.batteryVoltageRail()?.value ?? 0, 4.22, accuracy: 0.01)
    }

    func testBatteryVoltageRejectsImplausible() {
        var snapshot = EnergySnapshot.empty
        snapshot.voltages = [
            SensorReading(name: "battery voltage", key: "VP0u", zone: .battery, kind: .voltage, value: 0.01, copies: 1)
        ]
        XCTAssertNil(snapshot.batteryVoltageRail())
    }
}
