import Foundation

/// 全部私有传感器的唯一入口。
///
/// 做成 actor 不是为了并发，而是为了**串行**：HID client 全进程只能有一个，
/// 扫描、报告刷新、设置页诊断如果同时读，第二个调用会拿回一屏 NaN。
/// 所有读取都排队进这里，一次只跑一个。
actor SensorProbe {

    static let shared = SensorProbe()

    private let hid: HIDSensorProbe?
    private let power: PowerSourceProbe?

    private init() {
        hid = HIDSensorProbe()
        power = PowerSourceProbe()
    }

    /// 采集一次。任何一块取不到都不抛错，只把对应字段留在「不可用」状态。
    func snapshot() -> EnergySnapshot {
        var snapshot = EnergySnapshot.empty
        snapshot.hidAvailable = hid != nil
        snapshot.iokitAvailable = power != nil

        if let hid {
            // 充电器的通道只在插电后出现，每次采集前重扫
            hid.rescan()
            let merged = SensorMath.merge(hid.read())
            snapshot.serviceCount = hid.serviceCount
            snapshot.droppedValues = merged.dropped
            snapshot.temperatures = merged.sensors.filter { $0.kind == .temperature }
            snapshot.currents = merged.sensors.filter { $0.kind == .current }
            snapshot.voltages = merged.sensors.filter { $0.kind == .voltage }
        }

        if let power {
            snapshot.power = readPower(power)
        }

        return snapshot
    }

    private func readPower(_ probe: PowerSourceProbe) -> EnergySnapshot.Power {
        var result = EnergySnapshot.Power()

        let registry = probe.registryProperties() ?? [:]
        if let connected = registry["ExternalConnected"] as? Bool {
            result.externalConnected = connected
        }

        let sources = probe.powerSources()
        let battery = sources.first { ($0["Type"] as? String) == "InternalBattery" } ?? sources.first
        if let battery {
            if let connected = battery["ExternalConnected"] as? Bool {
                result.externalConnected = connected
            }
            result.charging = (battery["IsCharging"] as? Bool) ?? false
            result.fullCharge = (battery["IsCharged"] as? Bool) ?? false
        }

        if let adapter = probe.adapterDetails() {
            result.adapterName = (adapter["Name"] as? String) ?? (adapter["Description"] as? String)
            let voltage = Self.convert(adapter["AdapterVoltage"] ?? adapter["Voltage"], milliThreshold: 1_000)
            let current = Self.convert(adapter["Current"], milliThreshold: 100)
            result.adapterVoltage = voltage
            result.adapterCurrent = current

            if let watts = Self.number(adapter["Watts"]) {
                result.adapterRatedWatts = watts
            } else if let voltage, let current {
                result.adapterRatedWatts = voltage * current
            }

            if let menu = adapter["UsbHvcMenu"] as? [[String: Any]] {
                result.adapterProfileCount = menu.count
            }
        }

        return result
    }

    // MARK: - 单位换算

    /// 适配器描述里电压可能是 mV 也可能是 V，电流可能是 mA 也可能是 A，
    /// 没有文档说明。阈值判断比猜字段名可靠：手机不存在 1000 V 的适配器。
    private static func convert(_ raw: Any?, milliThreshold: Double) -> Double? {
        guard let value = number(raw), value > 0 else { return nil }
        return value >= milliThreshold ? value / 1_000 : value
    }

    private static func number(_ raw: Any?) -> Double? {
        if let number = raw as? NSNumber { return number.doubleValue }
        if let value = raw as? Double { return value }
        if let value = raw as? Int { return Double(value) }
        return nil
    }
}
