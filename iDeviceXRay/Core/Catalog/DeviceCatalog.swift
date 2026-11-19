import Foundation
import Observation

/// 单个机型的静态规格。
///
/// 字段大量为可选：机型名称与芯片来自 AppleDB（全覆盖），而屏幕尺寸、PPI、
/// 电池设计容量这类参数没有公开数据源，只能逐个机型人工核对。没核对过的就是
/// nil，界面显示「未收录」并说明原因 —— 不用推断值把它填满。
public struct DeviceSpec: Codable, Identifiable, Hashable, Sendable {
    public var id: String { identifier }

    public let identifier: String        // "iPhone17,1"
    public let name: String              // "iPhone 16 Pro"
    public let family: String            // "iPhone" / "iPad"
    public let chip: String?             // "A18 Pro"
    public let ramGB: Int?
    public let screenInches: Double?
    public let nativeWidth: Int?
    public let nativeHeight: Int?
    public let ppi: Int?
    public let refreshRate: Int?
    public let panelType: String?
    public let batteryDesignMah: Int?
    public let releaseYear: Int?
    public let modelNumbers: [String]?   // "A3256" 等销售型号
    /// "curated" = 规格经人工核对；"name-only" = 只知道名字与芯片
    public let specSource: String?

    public init(
        identifier: String,
        name: String,
        family: String,
        chip: String? = nil,
        ramGB: Int? = nil,
        screenInches: Double? = nil,
        nativeWidth: Int? = nil,
        nativeHeight: Int? = nil,
        ppi: Int? = nil,
        refreshRate: Int? = nil,
        panelType: String? = nil,
        batteryDesignMah: Int? = nil,
        releaseYear: Int? = nil,
        modelNumbers: [String]? = nil,
        specSource: String? = nil
    ) {
        self.identifier = identifier
        self.name = name
        self.family = family
        self.chip = chip
        self.ramGB = ramGB
        self.screenInches = screenInches
        self.nativeWidth = nativeWidth
        self.nativeHeight = nativeHeight
        self.ppi = ppi
        self.refreshRate = refreshRate
        self.panelType = panelType
        self.batteryDesignMah = batteryDesignMah
        self.releaseYear = releaseYear
        self.modelNumbers = modelNumbers
        self.specSource = specSource
    }

    /// 屏幕与电池这类需要人工核对的参数是否齐全
    public var hasDetailedSpecs: Bool { ppi != nil }
}

/// 机型库。离线内置，随版本更新；由 `Tools/build_catalog.py` 生成。
@Observable
public final class DeviceCatalog {
    public static let shared = DeviceCatalog()

    public private(set) var version: String = "未加载"
    public private(set) var devices: [DeviceSpec] = []

    private var index: [String: DeviceSpec] = [:]

    public init() {
        load()
    }

    private struct Payload: Decodable {
        let version: String
        let devices: [DeviceSpec]
    }

    private func load() {
        guard let url = Bundle.main.url(forResource: "devices", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            version = "未找到机型库"
            return
        }
        do {
            let payload = try JSONDecoder().decode(Payload.self, from: data)
            version = payload.version
            devices = payload.devices
            index = Dictionary(payload.devices.map { ($0.identifier, $0) }, uniquingKeysWith: { first, _ in first })
        } catch {
            version = "机型库解析失败"
        }
    }

    public func spec(for identifier: String) -> DeviceSpec? {
        index[identifier]
    }

    /// 只认识名字、没有核对过屏幕与电池参数的机型
    public func hasDetailedSpecs(_ identifier: String) -> Bool {
        index[identifier]?.hasDetailedSpecs ?? false
    }

    public func search(_ keyword: String) -> [DeviceSpec] {
        guard !keyword.isEmpty else { return devices }
        return devices.filter {
            $0.name.localizedCaseInsensitiveContains(keyword)
                || $0.identifier.localizedCaseInsensitiveContains(keyword)
        }
    }
}
