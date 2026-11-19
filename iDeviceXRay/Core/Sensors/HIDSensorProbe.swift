import Foundation

/// 通过私有 `IOHIDEventSystemClient` 读取 PMU 与整机温度传感器。
///
/// 两个 vendor usage page：
///   `0xFF08` AppleVendorPowerSensor — usage 2 电流(A)、usage 3 电压(V)
///   `0xFF00` AppleVendor            — usage 5 温度(°C)
///
/// **一个进程只能建一个 client**：第二个 client 对每个 service 都返回 NaN。
/// 所以这里不做单例约束，而由 `SensorProbe` actor 持有一个实例，全进程共用。
final class HIDSensorProbe {

    private typealias CreateFn = @convention(c) (CFAllocator?) -> Unmanaged<CFTypeRef>?
    private typealias SetMatchingFn = @convention(c) (CFTypeRef, CFDictionary?) -> Void
    private typealias CopyServicesFn = @convention(c) (CFTypeRef) -> Unmanaged<CFArray>?
    private typealias CopyPropertyFn = @convention(c) (CFTypeRef, CFString) -> Unmanaged<CFTypeRef>?
    private typealias CopyEventFn = @convention(c) (CFTypeRef, Int64, Int32, Int64) -> Unmanaged<CFTypeRef>?
    private typealias GetFloatFn = @convention(c) (CFTypeRef, Int32) -> Double

    private static let powerEventType: Int64 = 25        // kIOHIDEventTypePower
    private static let temperatureEventType: Int64 = 15  // kIOHIDEventTypeTemperature

    private struct Service {
        let ref: CFTypeRef
        let name: String
        let key: String
        let usage: Int
        let eventType: Int64
    }

    private let client: CFTypeRef
    private let setMatching: SetMatchingFn
    private let copyServices: CopyServicesFn
    private let copyProperty: CopyPropertyFn
    private let copyEvent: CopyEventFn
    private let getFloat: GetFloatFn
    private var services: [Service] = []

    var serviceCount: Int { services.count }

    init?() {
        guard let handle = DynamicLink.open(DynamicLink.iokitPath) else { return nil }
        guard let create = DynamicLink.symbol(handle, "IOHIDEventSystemClientCreate", as: CreateFn.self),
              let matching = DynamicLink.symbol(handle, "IOHIDEventSystemClientSetMatching", as: SetMatchingFn.self),
              let copyServices = DynamicLink.symbol(handle, "IOHIDEventSystemClientCopyServices", as: CopyServicesFn.self),
              let copyProperty = DynamicLink.symbol(handle, "IOHIDServiceClientCopyProperty", as: CopyPropertyFn.self),
              let copyEvent = DynamicLink.symbol(handle, "IOHIDServiceClientCopyEvent", as: CopyEventFn.self),
              let getFloat = DynamicLink.symbol(handle, "IOHIDEventGetFloatValue", as: GetFloatFn.self),
              let rawClient = create(kCFAllocatorDefault)?.takeRetainedValue()
        else { return nil }

        self.client = rawClient
        self.setMatching = matching
        self.copyServices = copyServices
        self.copyProperty = copyProperty
        self.copyEvent = copyEvent
        self.getFloat = getFloat
        rescan()
    }

    /// 重新枚举传感器。充电器的通道只在插上电源后才出现，所以每次采集前都会调一次。
    func rescan() {
        var found: [Service] = []
        // 电源页全部服务，不只认识的几个：没名字的轨道也能读到电压电流
        found += discover(matching: ["PrimaryUsagePage": 0xFF08], eventType: Self.powerEventType)
        // 温度矩阵全部服务
        found += discover(matching: ["PrimaryUsagePage": 0xFF00, "PrimaryUsage": 5],
                          eventType: Self.temperatureEventType)
        services = found
    }

    /// 读一遍所有传感器的当前值。返回 NaN 的（没插电、轨道断电）直接跳过，
    /// 不当成 0 —— 0 °C 和「读不到」是两件事。
    func read() -> [RawSensor] {
        services.enumerated().compactMap { index, service in
            guard let event = copyEvent(service.ref, service.eventType, 0, 0)?.takeRetainedValue() else { return nil }
            let value = getFloat(event, Int32(service.eventType << 16))
            guard value.isFinite else { return nil }
            let kind: SensorKind
            switch service.usage {
            case 2: kind = .current
            case 3: kind = .voltage
            case 5: kind = .temperature
            default: kind = .current
            }
            return RawSensor(name: service.name, key: service.key, index: index, kind: kind, value: value)
        }
    }

    private func discover(matching: [String: Any], eventType: Int64) -> [Service] {
        let cfMatching: CFDictionary? = matching as CFDictionary
        setMatching(client, cfMatching)
        let refs = copyServices(client)?.takeRetainedValue() as? [CFTypeRef] ?? []
        return refs.map { ref in
            let name = copyProperty(ref, "Product" as CFString)?.takeRetainedValue() as? String ?? "未命名传感器"
            let location = (copyProperty(ref, "LocationID" as CFString)?.takeRetainedValue() as? NSNumber)?.uint32Value ?? 0
            let usage = (copyProperty(ref, "PrimaryUsage" as CFString)?.takeRetainedValue() as? NSNumber)?.intValue ?? 0
            return Service(ref: ref, name: name, key: Self.smcKey(location), usage: usage, eventType: eventType)
        }
    }

    /// `LocationID` 里打包着四字母 SMC 键（`0x49513075` = `IQ0u`）。
    /// 不是四个可打印字符就返回空 —— 顺序编号不能被编成一个看着像真的键。
    static func smcKey(_ location: UInt32) -> String {
        guard location != 0 else { return "" }
        let bytes = withUnsafeBytes(of: location.bigEndian) { Array($0) }
        guard bytes.count == 4, bytes.allSatisfy({ (0x20...0x7E).contains($0) }) else { return "" }
        return String(decoding: bytes, as: UTF8.self)
    }
}
