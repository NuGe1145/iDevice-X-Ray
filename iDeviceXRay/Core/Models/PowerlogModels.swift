import Foundation

// MARK: - Powerlog 摘要
//
// 这是全项目唯一能给出「历史」而不只是「当下」的数据源。
// 数据来自 sysdiagnose 里的 `CurrentPowerlog.PLSQL`，由 powerlogd 持续写入。
//
// 原则不变：只报解出来的值，解不出就返回 nil，由调用方显示「—」并说明原因。

public struct PowerlogSummary: Codable, Hashable, Sendable {

    public struct Point: Codable, Hashable, Sendable {
        public let time: Date
        public let value: Double
    }

    /// 实际命中的数据表与列名。字段映射随 iOS 版本变化，所以这两项要交给用户看见，
    /// 出问题时截图就能定位，不必让他描述。
    public let table: String
    public let matchedColumns: [String]
    public let rowCount: Int
    /// 库里一共找到几张 PLBatteryAgent 表
    public let candidateTables: Int

    public let cycleCount: Int?
    public let designCapacity: Int?
    public let maxCapacity: Int?
    public let latestTemperature: Double?
    public let latestVoltage: Double?

    public let firstSample: Date?
    public let lastSample: Date?

    /// 容量曲线。有设计容量时是百分比，否则是 mAh，单位见 `capacityUnit`。
    public let capacitySeries: [Point]
    public let capacityUnit: String
    public let temperatureSeries: [Point]

    public init(
        table: String,
        matchedColumns: [String],
        rowCount: Int,
        candidateTables: Int,
        cycleCount: Int?,
        designCapacity: Int?,
        maxCapacity: Int?,
        latestTemperature: Double?,
        latestVoltage: Double?,
        firstSample: Date?,
        lastSample: Date?,
        capacitySeries: [Point],
        capacityUnit: String,
        temperatureSeries: [Point]
    ) {
        self.table = table
        self.matchedColumns = matchedColumns
        self.rowCount = rowCount
        self.candidateTables = candidateTables
        self.cycleCount = cycleCount
        self.designCapacity = designCapacity
        self.maxCapacity = maxCapacity
        self.latestTemperature = latestTemperature
        self.latestVoltage = latestVoltage
        self.firstSample = firstSample
        self.lastSample = lastSample
        self.capacitySeries = capacitySeries
        self.capacityUnit = capacityUnit
        self.temperatureSeries = temperatureSeries
    }

    /// 健康度：实际最大容量 ÷ 设计容量。超出 25–130% 视为解错，宁可返回 nil。
    public var healthPercent: Double? {
        guard let maxCapacity, let designCapacity, designCapacity > 0, maxCapacity > 0 else { return nil }
        let percent = Double(maxCapacity) / Double(designCapacity) * 100
        return (25...130).contains(percent) ? percent : nil
    }

    public var spanDays: Int? {
        guard let firstSample, let lastSample, lastSample > firstSample else { return nil }
        return Int(lastSample.timeIntervalSince(firstSample) / 86_400)
    }

    public var hasAnything: Bool {
        cycleCount != nil
            || designCapacity != nil
            || maxCapacity != nil
            || !capacitySeries.isEmpty
            || !temperatureSeries.isEmpty
    }

    /// 与 ReportModels 里字段 key 对齐的展示串，交给 DataFusion 覆盖占位字段
    public var extraction: [String: String] {
        var values: [String: String] = [:]

        if let cycleCount {
            values["battery.cycleCount"] = "\(cycleCount) 次"
        }
        if let designCapacity {
            values["battery.designCapacity"] = "\(designCapacity) mAh"
        }
        if let maxCapacity {
            values["battery.maxCapacity"] = "\(maxCapacity) mAh"
        }
        if let healthPercent {
            values["battery.health"] = String(format: "%.0f%%", healthPercent)
        }
        if let latestTemperature {
            values["battery.temperature"] = String(format: "%.1f °C", latestTemperature)
        }
        if let latestVoltage {
            values["battery.voltage"] = String(format: "%.2f V", latestVoltage)
        }
        if let spanDays, spanDays > 0 {
            let start = firstSample.map { Self.dayFormatter.string(from: $0) } ?? ""
            values["battery.historySpan"] = start.isEmpty ? "\(spanDays) 天" : "\(spanDays) 天（\(start) 起）"
        }

        return values
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
