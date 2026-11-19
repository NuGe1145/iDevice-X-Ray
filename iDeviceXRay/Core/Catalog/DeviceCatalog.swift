import Foundation
import Observation

/// 单个机型的静态规格。这些数值无法从系统 API 读取，只能靠型号库匹配，
/// 因此每一条都标记为 `.catalog` / `.inferred`。
public struct DeviceSpec: Codable, Identifiable, Hashable, Sendable {
    public var id: String { identifier }

    public let identifier: String        // "iPhone17,1"
    public let name: String              // "iPhone 16 Pro"
    public let family: String            // "iPhone" / "iPad"
    public let chip: String              // "A18 Pro"
    public let ramGB: Int
    public let screenInches: Double
    public let nativeWidth: Int
    public let nativeHeight: Int
    public let ppi: Int
    public let refreshRate: Int
    public let panelType: String         // "OLED (LTPO)" / "LCD"
    public let batteryDesignMah: Int?
    public let releaseYear: Int

    public init(
        identifier: String,
        name: String,
        family: String,
        chip: String,
        ramGB: Int,
        screenInches: Double,
        nativeWidth: Int,
        nativeHeight: Int,
        ppi: Int,
        refreshRate: Int,
        panelType: String,
        batteryDesignMah: Int?,
        releaseYear: Int
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
    }
}

/// 机型库。离线内置，随版本更新。
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

    public func search(_ keyword: String) -> [DeviceSpec] {
        guard !keyword.isEmpty else { return devices }
        return devices.filter {
            $0.name.localizedCaseInsensitiveContains(keyword)
                || $0.identifier.localizedCaseInsensitiveContains(keyword)
        }
    }
}
