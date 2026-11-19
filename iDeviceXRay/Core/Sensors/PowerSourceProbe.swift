import Foundation

/// 通过 IOKit 读电源与适配器信息。
///
/// 真机上活下来的只有这些：
/// - `IOPMPowerSource` 注册表：只剩 `BatteryInstalled`、`ExternalConnected` 两个键，
///   其余（循环次数、健康度、电压、温度）被系统过滤掉了。
/// - `IOPSCopyPowerSourcesInfo`：电量、充电标志、低电量模式。
/// - `IOPSCopyExternalPowerAdapterDetails`：USB-PD 握手结果。
///
/// 所以这里不做「读不到就编一个」的事：拿不到就是 nil，交上层标成不可用。
final class PowerSourceProbe {

    private typealias ServiceMatchingFn = @convention(c) (UnsafePointer<CChar>) -> Unmanaged<CFDictionary>?
    private typealias GetMatchingServiceFn = @convention(c) (UInt32, CFDictionary?) -> UInt32
    private typealias CreatePropertiesFn = @convention(c) (UInt32, UnsafeMutablePointer<Unmanaged<CFDictionary>?>?, CFAllocator?, UInt32) -> Int32
    private typealias ObjectReleaseFn = @convention(c) (UInt32) -> Int32
    private typealias CopyPowerSourcesInfoFn = @convention(c) () -> Unmanaged<CFTypeRef>?
    private typealias CopyPowerSourcesListFn = @convention(c) (CFTypeRef) -> Unmanaged<CFArray>?
    private typealias PowerSourceDescriptionFn = @convention(c) (CFTypeRef, CFTypeRef) -> Unmanaged<CFDictionary>?
    private typealias CopyAdapterDetailsFn = @convention(c) () -> Unmanaged<CFDictionary>?

    private let serviceMatching: ServiceMatchingFn
    private let getMatchingService: GetMatchingServiceFn
    private let createProperties: CreatePropertiesFn
    private let objectRelease: ObjectReleaseFn
    private let copyPowerSourcesInfo: CopyPowerSourcesInfoFn?
    private let copyPowerSourcesList: CopyPowerSourcesListFn?
    private let powerSourceDescription: PowerSourceDescriptionFn?
    private let copyAdapterDetails: CopyAdapterDetailsFn?

    init?() {
        guard let handle = DynamicLink.open(DynamicLink.iokitPath) else { return nil }
        guard let matching = DynamicLink.symbol(handle, "IOServiceMatching", as: ServiceMatchingFn.self),
              let getService = DynamicLink.symbol(handle, "IOServiceGetMatchingService", as: GetMatchingServiceFn.self),
              let properties = DynamicLink.symbol(handle, "IORegistryEntryCreateCFProperties", as: CreatePropertiesFn.self),
              let release = DynamicLink.symbol(handle, "IOObjectRelease", as: ObjectReleaseFn.self)
        else { return nil }

        serviceMatching = matching
        getMatchingService = getService
        createProperties = properties
        objectRelease = release
        copyPowerSourcesInfo = DynamicLink.symbol(handle, "IOPSCopyPowerSourcesInfo", as: CopyPowerSourcesInfoFn.self)
        copyPowerSourcesList = DynamicLink.symbol(handle, "IOPSCopyPowerSourcesList", as: CopyPowerSourcesListFn.self)
        powerSourceDescription = DynamicLink.symbol(handle, "IOPSGetPowerSourceDescription", as: PowerSourceDescriptionFn.self)
        copyAdapterDetails = DynamicLink.symbol(handle, "IOPSCopyExternalPowerAdapterDetails", as: CopyAdapterDetailsFn.self)
    }

    /// `IOPMPowerSource` 的完整属性表。真机上通常只剩两个键。
    func registryProperties() -> [String: Any]? {
        guard let matching = serviceMatching("IOPMPowerSource") else { return nil }
        // IOServiceGetMatchingService 会吃掉 IOServiceMatching 返回的 +1 引用，
        // 所以这里不 takeRetainedValue，否则会二次释放。
        let service = getMatchingService(0, matching.takeUnretainedValue())
        guard service != 0 else { return nil }
        defer { _ = objectRelease(service) }

        var properties: Unmanaged<CFDictionary>?
        guard createProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dictionary = properties?.takeRetainedValue() else { return nil }
        return dictionary as? [String: Any]
    }

    /// powerd 上报的每个电源（真机上只有内置电池那一条）。
    func powerSources() -> [[String: Any]] {
        guard let copyPowerSourcesInfo, let copyPowerSourcesList, let powerSourceDescription,
              let blob = copyPowerSourcesInfo()?.takeRetainedValue(),
              let list = copyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return [] }
        return list.compactMap { powerSourceDescription(blob, $0)?.takeUnretainedValue() as? [String: Any] }
    }

    /// 已连接适配器的描述，含 USB-PD 档位表。
    func adapterDetails() -> [String: Any]? {
        copyAdapterDetails?()?.takeRetainedValue() as? [String: Any]
    }
}
