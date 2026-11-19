import Foundation

// MARK: - 传感器分类

/// 传感器在机身里的位置。
///
/// 名字在不同机型上会变（iPhone 17 上有四个都叫 `gas gauge battery`），
/// 所以不按名字精确匹配，而是按关键词归类；认不出的落到 `.other` 但仍然显示。
/// 新型号退化成更长的「其他」列表，而不是一块空屏。
enum ThermalZone: String, CaseIterable, Sendable {
    case battery
    case charger
    case wireless
    case soc
    case storage
    case display
    case camera
    case radio
    case chassis
    case other

    var title: String {
        switch self {
        case .battery: return "电池"
        case .charger: return "充电 IC"
        case .wireless: return "无线充电"
        case .soc: return "SoC / CPU"
        case .storage: return "存储"
        case .display: return "屏幕"
        case .camera: return "摄像头"
        case .radio: return "射频"
        case .chassis: return "机身"
        case .other: return "其他"
        }
    }

    var order: Int {
        switch self {
        case .battery: return 0
        case .charger: return 1
        case .wireless: return 2
        case .soc: return 3
        case .storage: return 4
        case .display: return 5
        case .camera: return 6
        case .radio: return 7
        case .chassis: return 8
        case .other: return 9
        }
    }

    /// 关键词命中顺序即优先级：`wireless charger` 先命中无线，不会被充电 IC 抢走。
    static func classify(name: String, key: String) -> ThermalZone {
        let text = (name + " " + key).lowercased()
        func has(_ words: [String]) -> Bool { words.contains { text.contains($0) } }

        if has(["wireless", "magsafe", "coil"]) { return .wireless }
        if has(["gas gauge", "battery", "tb0", "tb1", "tb2"]) { return .battery }
        if has(["charger", "charge ic", "usb", "tq0", "iq0", "vq0", "vp0"]) { return .charger }
        if has(["tdie", "soc", "cpu", "gpu", "ane", "isp", "effic"]) { return .soc }
        if has(["nand", "ssd", "flash", "storage"]) { return .storage }
        if has(["display", "backlight", "lcd", "oled", "panel"]) { return .display }
        if has(["camera", "cam0", "cam1", "front cam"]) { return .camera }
        if has(["radio", "modem", "antenna", "wifi", "bb ", " rf"]) { return .radio }
        if has(["surface", "chassis", "case", "skin", "encl"]) { return .chassis }
        return .other
    }
}

enum SensorKind: Sendable, Hashable {
    case current
    case voltage
    case temperature
}

/// HID 层交出来的原始一行，未经合并、未经合理性过滤。
struct RawSensor: Sendable {
    let name: String
    let key: String
    let index: Int
    let kind: SensorKind
    let value: Double
}

/// 合并后的一个传感器。
struct SensorReading: Hashable, Sendable {
    let name: String
    /// SMC 四字母键，如 `IQ0u`。拿不到时为 ""。
    let key: String
    let zone: ThermalZone
    let kind: SensorKind
    let value: Double
    /// 合并了几个 service。iOS 27 起同一个 key 会发两遍，正常是 1 或 2。
    let copies: Int

    var identifier: String { key.isEmpty ? "\(zone.rawValue).\(name)" : key }
}

// MARK: - 合理性过滤与合并

enum SensorMath {

    /// 一台手机上的传感器能报出的物理范围。超出这个区间不是「很冷」，
    /// 而是这个通道根本不代表温度：社区里有充电 IC 报 −9199.4 °C 的记录。
    /// 这类值一律丢弃并计数，不让它进报告。
    static let plausibleCelsius = -40.0...150.0

    /// 按 SMC key 合并重复 service 并过滤不可能的值。
    ///
    /// 合并取**平均**而不是求和 —— 同一个 key 的两条记录是同一测量的两份副本，
    /// 相加会把温度变成两倍，这是这块最容易犯且最难发现的错。
    static func merge(_ raw: [RawSensor]) -> (sensors: [SensorReading], dropped: Int) {
        var buckets: [String: (name: String, zone: ThermalZone, kind: SensorKind, sum: Double, count: Int)] = [:]
        var dropped = 0

        for item in raw {
            guard item.value.isFinite else { continue }
            if item.kind == .temperature, !plausibleCelsius.contains(item.value) {
                dropped += 1
                continue
            }
            let identifier = item.key.isEmpty ? "\(item.name)#\(item.index)" : item.key
            let zone = ThermalZone.classify(name: item.name, key: item.key)
            if var existing = buckets[identifier] {
                existing.sum += item.value
                existing.count += 1
                buckets[identifier] = existing
            } else {
                buckets[identifier] = (item.name, zone, item.kind, item.value, 1)
            }
        }

        let sensors = buckets.map { identifier, bucket in
            SensorReading(
                name: bucket.name,
                key: identifier.contains("#") ? "" : identifier,
                zone: bucket.zone,
                kind: bucket.kind,
                value: bucket.sum / Double(bucket.count),
                copies: bucket.count
            )
        }
        .sorted { lhs, rhs in
            if lhs.zone.order != rhs.zone.order { return lhs.zone.order < rhs.zone.order }
            return lhs.name < rhs.name
        }

        return (sensors, dropped)
    }
}

// MARK: - 快照

/// 一次采集的完整结果，纯值类型，可以安全跨 actor 传递。
/// IOKit 的字典不离开采集 actor，UI 层只会看到这里的字段。
struct EnergySnapshot: Sendable {

    struct Power: Sendable {
        var externalConnected = false
        var charging = false
        var fullCharge = false
        var adapterName: String?
        var adapterRatedWatts: Double?
        var adapterVoltage: Double?
        var adapterCurrent: Double?
        var adapterProfileCount: Int = 0
    }

    var temperatures: [SensorReading] = []
    var currents: [SensorReading] = []
    var voltages: [SensorReading] = []
    var power = Power()
    var serviceCount = 0
    var droppedValues = 0
    var hidAvailable = false
    var iokitAvailable = false

    static let empty = EnergySnapshot()

    func current(_ key: String) -> SensorReading? { currents.first { $0.key == key } }
    func voltage(_ key: String) -> SensorReading? { voltages.first { $0.key == key } }

    func hottest(in zones: [ThermalZone]) -> SensorReading? {
        temperatures
            .filter { zones.contains($0.zone) }
            .max { $0.value < $1.value }
    }
}
