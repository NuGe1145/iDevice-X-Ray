import Foundation

// MARK: - 数据来源与可信度
//
// 这是整个产品的核心契约：任何展示给用户的数值，都必须能回答两个问题
// 「这个数从哪来」「我该不该信」。没有来源的数据一律不显示。

public enum DataSource: String, Codable, Hashable, CaseIterable, Sendable {
    case live          // 直接从系统 API 实时读取
    case sysdiagnose   // 由用户导入的诊断档案解析
    case catalog       // 由机型规格库匹配
    case manual        // 用户手动录入

    public var displayName: String {
        switch self {
        case .live: return "实时读取"
        case .sysdiagnose: return "诊断档案"
        case .catalog: return "机型库"
        case .manual: return "手动录入"
        }
    }

    public var symbolName: String {
        switch self {
        case .live: return "waveform.path.ecg"
        case .sysdiagnose: return "doc.text.magnifyingglass"
        case .catalog: return "books.vertical.fill"
        case .manual: return "square.and.pencil"
        }
    }
}

public enum Confidence: Int, Codable, Hashable, Comparable, CaseIterable, Sendable {
    case unavailable = 0   // 受系统限制，无法读取
    case inferred = 1      // 由型号库或日志推断，可能不准
    case high = 2          // 可信，但非系统直接读取
    case verified = 3      // 系统 API 直接读取，已验证

    public static func < (lhs: Confidence, rhs: Confidence) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var displayName: String {
        switch self {
        case .unavailable: return "不可读取"
        case .inferred: return "推断"
        case .high: return "较可信"
        case .verified: return "已验证"
        }
    }

    public var symbolName: String {
        switch self {
        case .unavailable: return "slash.circle"
        case .inferred: return "questionmark.circle"
        case .high: return "checkmark.circle"
        case .verified: return "checkmark.seal.fill"
        }
    }
}

// MARK: - 字段

public struct ReportField: Codable, Identifiable, Hashable, Sendable {
    public var id: String { key }

    /// 稳定标识，如 "battery.cycleCount"，用于深度数据融合覆盖
    public let key: String
    public let title: String
    public let value: String
    public let unit: String?
    public let source: DataSource
    public let confidence: Confidence
    public let note: String?

    public init(
        key: String,
        title: String,
        value: String,
        unit: String? = nil,
        source: DataSource,
        confidence: Confidence,
        note: String? = nil
    ) {
        self.key = key
        self.title = title
        self.value = value
        self.unit = unit
        self.source = source
        self.confidence = confidence
        self.note = note
    }

    public static func unavailable(
        key: String,
        title: String,
        value: String = "",
        reason: String
    ) -> ReportField {
        ReportField(
            key: key,
            title: title,
            value: value,
            source: .live,
            confidence: .unavailable,
            note: reason
        )
    }

    /// 面向 UI 的展示串，读不到时统一显示破折号，绝不编造数值
    public var displayValue: String {
        guard confidence != .unavailable, !value.isEmpty else { return "—" }
        if let unit, !unit.isEmpty {
            if unit == "%" { return "\(value)%" }
            return "\(value) \(unit)"
        }
        return value
    }

    public var footnote: String? {
        if let note, !note.isEmpty { return note }
        switch confidence {
        case .unavailable: return nil
        case .inferred: return "由机型库或日志推断，仅供参考"
        case .high: return "来源：\(source.displayName)"
        case .verified: return "来源：\(source.displayName)"
        }
    }
}

// MARK: - 分区

public struct ReportSection: Codable, Identifiable, Hashable, Sendable {
    public var id: String { key }

    public let key: String
    public let title: String
    public let symbol: String
    public let accentHex: UInt32
    public let fields: [ReportField]

    public init(
        key: String,
        title: String,
        symbol: String,
        accentHex: UInt32,
        fields: [ReportField]
    ) {
        self.key = key
        self.title = title
        self.symbol = symbol
        self.accentHex = accentHex
        self.fields = fields
    }

    public var readableCount: Int {
        fields.filter { $0.confidence != .unavailable }.count
    }
}

// MARK: - 深度扫描结果

public struct DeepScanResult: Codable, Hashable, Sendable {
    public let fileName: String
    public let fileSizeBytes: Int64
    public let parsedAt: Date
    public let entriesScanned: Int
    public let matchedFiles: [String]
    /// 归一化后的键值，如 ["battery.cycleCount": "258"]
    public let extraction: [String: String]
    public let warnings: [String]
    public let durationSeconds: Double

    public init(
        fileName: String,
        fileSizeBytes: Int64,
        parsedAt: Date = Date(),
        entriesScanned: Int,
        matchedFiles: [String],
        extraction: [String: String],
        warnings: [String],
        durationSeconds: Double
    ) {
        self.fileName = fileName
        self.fileSizeBytes = fileSizeBytes
        self.parsedAt = parsedAt
        self.entriesScanned = entriesScanned
        self.matchedFiles = matchedFiles
        self.extraction = extraction
        self.warnings = warnings
        self.durationSeconds = durationSeconds
    }
}

// MARK: - 报告

public enum ScanMode: String, Codable, Hashable, Sendable {
    case standard
    case deep

    public var displayName: String {
        switch self {
        case .standard: return "标准检测"
        case .deep: return "深度检测"
        }
    }
}

public struct ScanReport: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public let mode: ScanMode
    public let deviceName: String
    public let identifier: String
    public let osVersion: String
    public let sections: [ReportSection]
    public let deep: DeepScanResult?

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        mode: ScanMode,
        deviceName: String,
        identifier: String,
        osVersion: String,
        sections: [ReportSection],
        deep: DeepScanResult? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.mode = mode
        self.deviceName = deviceName
        self.identifier = identifier
        self.osVersion = osVersion
        self.sections = sections
        self.deep = deep
    }

    public var allFields: [ReportField] {
        sections.flatMap(\.fields)
    }

    public var totalCount: Int { allFields.count }

    public var readableCount: Int {
        allFields.filter { $0.confidence != .unavailable }.count
    }

    public var verifiedCount: Int {
        allFields.filter { $0.confidence == .verified }.count
    }

    /// 报告完整度 0–100，用于封面展示，不代表设备好坏
    public var completenessScore: Int {
        guard !allFields.isEmpty else { return 0 }
        let weighted = allFields.reduce(0.0) { partial, field in
            switch field.confidence {
            case .verified: return partial + 1.0
            case .high: return partial + 0.8
            case .inferred: return partial + 0.5
            case .unavailable: return partial
            }
        }
        return Int((weighted / Double(allFields.count) * 100).rounded())
    }

    public func section(_ key: String) -> ReportSection? {
        sections.first { $0.key == key }
    }
}
