import XCTest
@testable import iDeviceXRay

/// 实时监控里那些不需要真机就能验证的部分：
/// 统计口径、指标取值优先级、以及电池页的实时回填。
final class ChargeLiveTests: XCTestCase {

    // MARK: 构造

    private func sample(
        id: Int = 1,
        inputVoltage: Double? = nil,
        inputCurrent: Double? = nil,
        inputWatts: Double? = nil,
        batteryVoltage: Double? = nil,
        batteryCurrent: Double? = nil,
        batteryWatts: Double? = nil,
        batteryTemperature: Double? = nil,
        chargerTemperature: Double? = nil,
        socTemperature: Double? = nil
    ) -> ChargeSample {
        ChargeSample(
            id: id,
            time: Date(),
            inputVoltage: inputVoltage,
            inputCurrent: inputCurrent,
            inputWatts: inputWatts,
            batteryVoltage: batteryVoltage,
            batteryCurrent: batteryCurrent,
            batteryWatts: batteryWatts,
            batteryTemperature: batteryTemperature,
            chargerTemperature: chargerTemperature,
            socTemperature: socTemperature,
            level: 0.6,
            state: .charging,
            adapterName: "20W USB-C",
            adapterRatedWatts: 20
        )
    }

    private func reading(_ key: String, _ value: Double, kind: SensorKind, zone: ThermalZone) -> SensorReading {
        SensorReading(name: key, key: key, zone: zone, kind: kind, value: value, copies: 1)
    }

    private func baseBatterySection() -> ReportSection {
        ReportSection(
            key: "battery",
            title: "电池状态",
            symbol: "battery.75percent",
            accentHex: 0x34D399,
            fields: [
                ReportField(key: "battery.level", title: "当前电量", value: "40", unit: "%", source: .live, confidence: .verified),
                ReportField(key: "battery.state", title: "充电状态", value: "使用电池", source: .live, confidence: .verified),
                .unavailable(key: "battery.voltage", title: "电池电压", reason: "需深度档案"),
                .unavailable(key: "battery.temperature", title: "电池温度", reason: "需深度档案")
            ]
        )
    }

    // MARK: 统计

    func testStatsFromValues() {
        let stats = ChargeStats.make([8.0, 9.0, 10.0])
        XCTAssertEqual(stats.minimum, 8.0)
        XCTAssertEqual(stats.maximum, 10.0)
        XCTAssertEqual(stats.average, 9.0)
        XCTAssertEqual(stats.count, 3)
    }

    func testStatsEmpty() {
        let stats = ChargeStats.make([])
        XCTAssertNil(stats.minimum)
        XCTAssertNil(stats.maximum)
        XCTAssertNil(stats.average)
        XCTAssertEqual(stats.count, 0)
    }

    // MARK: 指标取值

    func testPowerMetricPrefersInput() {
        let item = sample(inputWatts: 8.9, batteryWatts: 7.6)
        XCTAssertEqual(ChargeMetric.power.value(item), 8.9)
    }

    func testPowerMetricFallsBackToBattery() {
        // 未插电时输入通道没有读数，退回电池端（负数代表放电）
        let item = sample(batteryWatts: -4.2)
        XCTAssertEqual(ChargeMetric.power.value(item), -4.2)
    }

    func testTemperatureMetricPrefersCharger() {
        let item = sample(batteryTemperature: 31.2, chargerTemperature: 38.4)
        XCTAssertEqual(ChargeMetric.temperature.value(item), 38.4)
    }

    func testMissingValuesStayNil() {
        let item = sample()
        XCTAssertNil(ChargeMetric.power.value(item))
        XCTAssertNil(ChargeMetric.current.value(item))
        XCTAssertNil(ChargeMetric.temperature.value(item))
    }

    func testBatteryCurrentMagnitudeIgnoresSign() {
        let charging = sample(batteryCurrent: 1.25)
        let discharging = sample(batteryCurrent: -0.86)
        XCTAssertEqual(charging.batteryCurrentMagnitude, 1.25)
        XCTAssertEqual(discharging.batteryCurrentMagnitude, 0.86)
    }

    // MARK: 电池页实时回填

    func testBatterySectionUsesLiveValues() {
        var snapshot = EnergySnapshot.empty
        snapshot.iokitAvailable = true
        snapshot.batteryLevel = 0.62
        snapshot.power.charging = true
        snapshot.voltages = [reading("VP0u", 4.05, kind: .voltage, zone: .battery)]
        snapshot.currents = [reading("IQ0B", 1.2, kind: .current, zone: .battery)]

        let live = PowerSensorEngine().liveSection(for: baseBatterySection(), from: snapshot)

        XCTAssertEqual(live.field("battery.level")?.value, "62")
        XCTAssertEqual(live.field("battery.state")?.value, "充电中")
        XCTAssertEqual(live.field("battery.voltage")?.value, "4.05")
        XCTAssertEqual(live.field("battery.voltage")?.confidence, .verified)
        // 实时值应当补出电流与功率两行
        XCTAssertNotNil(live.field("battery.current"))
        XCTAssertNotNil(live.field("battery.power"))
        XCTAssertEqual(live.field("battery.power")?.value, "4.86")
    }

    func testBatterySectionWhenUnpluggedHasNoFakeCurrent() {
        var snapshot = EnergySnapshot.empty
        snapshot.iokitAvailable = true
        snapshot.batteryLevel = 0.62

        let live = PowerSensorEngine().liveSection(for: baseBatterySection(), from: snapshot)

        XCTAssertEqual(live.field("battery.state")?.value, "使用电池")
        XCTAssertNil(live.field("battery.current"))
        XCTAssertNil(live.field("battery.power"))
    }

    func testBatterySectionKeepsUnknownFields() {
        var snapshot = EnergySnapshot.empty
        snapshot.iokitAvailable = true
        snapshot.batteryLevel = 0.5

        let live = PowerSensorEngine().liveSection(for: baseBatterySection(), from: snapshot)

        // 没有传感器读数时不要用 0 填充，仍是「不可读取」
        XCTAssertEqual(live.field("battery.temperature")?.confidence, .unavailable)
    }
}

private extension ReportSection {
    func field(_ key: String) -> ReportField? {
        fields.first { $0.key == key }
    }
}
