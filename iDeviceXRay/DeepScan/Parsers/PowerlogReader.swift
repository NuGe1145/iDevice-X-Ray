import Foundation
import SQLite3

/// 读取 `CurrentPowerlog.PLSQL`。
///
/// 不假设表结构：先列出所有 `PLBatteryAgent*` 表，对每张表读 `PRAGMA table_info`，
/// 按列名分配「角色」（时间戳 / 循环次数 / 容量 / 温度…），再挑命中角色最多的一张查。
/// 写死列名一定会在某个 iOS 版本上失效，而 powerlog 的表结构每代都在变。
enum PowerlogReader {

    struct Outcome {
        var summary: PowerlogSummary?
        var notes: [String] = []
    }

    /// 单表最多取多少行。60 秒一条的话 3 万行约等于 20 天，够画衰减曲线了。
    private static let maxRows = 30_000

    // MARK: - 列角色

    private enum Role: Hashable {
        case timestamp, cycleCount, designCapacity, maxCapacity, currentCapacity
        case temperature, voltage, amperage
    }

    private static let aliases: [Role: Set<String>] = [
        .timestamp: ["timestamp", "time", "datetime"],
        .cycleCount: ["cyclecount"],
        .designCapacity: ["designcapacity", "nominalchargecapacity", "nominalcapacity"],
        .maxCapacity: ["applerawmaxcapacity", "rawmaxcapacity", "applemaxcapacity", "maxcapacity"],
        .currentCapacity: ["applerawcurrentcapacity", "rawcurrentcapacity", "applecurrentcapacity", "currentcapacity"],
        .temperature: ["temperature", "batterytemperature"],
        .voltage: ["voltage", "batteryvoltage"],
        .amperage: ["amperage", "instantamperage"]
    ]

    // MARK: - 入口

    static func read(url: URL) -> Outcome {
        var outcome = Outcome()

        guard FileManager.default.fileExists(atPath: url.path) else {
            outcome.notes.append("Powerlog 文件不存在，可能该档案未包含 logs/powerlogs")
            return outcome
        }

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let db = handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "未知原因"
            sqlite3_close(handle)
            outcome.notes.append("Powerlog 无法打开（\(message)），跳过电池历史")
            return outcome
        }
        defer { sqlite3_close(db) }

        sqlite3_busy_timeout(db, 2_000)

        let candidates = tableNames(db).filter { $0.lowercased().hasPrefix("plbatteryagent") }
        guard !candidates.isEmpty else {
            let total = tableNames(db).count
            outcome.notes.append("Powerlog 已打开（\(total) 张表），但没有 PLBatteryAgent 表，电池历史不可用")
            return outcome
        }

        var best: (table: String, columns: [Role: String], score: Int)?
        for table in candidates {
            let columns = columnsOf(db, table: table)
            let mapping = mapRoles(columns)
            guard mapping[.timestamp] != nil else { continue }
            let score = scoreOf(mapping)
            if score > (best?.score ?? 0) {
                best = (table, mapping, score)
            }
        }

        guard let best else {
            outcome.notes.append("找到 \(candidates.count) 张 PLBatteryAgent 表，但没有一张带时间戳列，无法按时间排序")
            return outcome
        }

        let summary = summarize(db, table: best.table, mapping: best.columns, candidateCount: candidates.count)
        outcome.summary = summary
        if summary == nil {
            outcome.notes.append("表 \(best.table) 结构未识别出可用列，需要真机样本补充映射")
        }
        return outcome
    }

    // MARK: - 汇总

    private static func summarize(
        _ db: OpaquePointer,
        table: String,
        mapping: [Role: String],
        candidateCount: Int
    ) -> PowerlogSummary? {
        guard let timestampColumn = mapping[.timestamp] else { return nil }

        var selected: [Role] = [.timestamp]
        for role in [Role.cycleCount, .designCapacity, .maxCapacity, .currentCapacity, .temperature, .voltage, .amperage] {
            if mapping[role] != nil { selected.append(role) }
        }
        guard selected.count > 1 else { return nil }

        let columnList = selected.compactMap { mapping[$0] }
            .map { quote($0) }
            .joined(separator: ", ")

        let sql = "SELECT \(columnList) FROM \(quote(table)) ORDER BY \(quote(timestampColumn)) DESC LIMIT \(maxRows)"
        let rows = query(db, sql)
        guard !rows.isEmpty else { return nil }

        var cycleCount: Int?
        var designCapacity: Int?
        var maxCapacity: Int?
        var latestTemperature: Double?
        var latestVoltage: Double?

        var capacities: [PowerlogSummary.Point] = []
        var temperatures: [PowerlogSummary.Point] = []

        // 倒序取回来，画图要从早到晚
        for row in rows {
            guard let rawTime = row[timestampColumn], let date = decodeDate(rawTime) else { continue }

            if let column = mapping[.cycleCount], let value = row[column], value > 0, value < 5_000 {
                cycleCount = cycleCount ?? Int(value)
            }
            if let column = mapping[.designCapacity], let value = row[column], value > 100, value < 20_000 {
                designCapacity = designCapacity ?? Int(value)
            }
            if let column = mapping[.maxCapacity], let value = row[column], value > 100, value < 20_000 {
                maxCapacity = maxCapacity ?? Int(value)
            }
            if let column = mapping[.temperature], let value = row[column], let celsius = decodeCelsius(value) {
                if latestTemperature == nil { latestTemperature = celsius }
                temperatures.append(.init(time: date, value: celsius))
            }
            if let column = mapping[.voltage], let value = row[column], let volts = decodeVolts(value) {
                if latestVoltage == nil { latestVoltage = volts }
            }
        }

        // 容量曲线：优先用每行的 max/design 算百分比，退化时用每行 current/max 算剩余量百分比
        let design = designCapacity
        for row in rows {
            guard let rawTime = row[timestampColumn], let date = decodeDate(rawTime) else { continue }

            if let column = mapping[.maxCapacity], let raw = row[column], raw > 100, raw < 20_000 {
                if let design, design > 0 {
                    let percent = raw / Double(design) * 100
                    if (25...130).contains(percent) {
                        capacities.append(.init(time: date, value: percent))
                    }
                } else {
                    capacities.append(.init(time: date, value: raw))
                }
            } else if let column = mapping[.currentCapacity],
                      let raw = row[column], raw > 100, raw < 20_000,
                      let max = maxCapacity, max > 0 {
                let percent = raw / Double(max) * 100
                if (0...110).contains(percent) {
                    capacities.append(.init(time: date, value: percent))
                }
            }
        }

        let sortedCapacity = capacities.sorted { $0.time < $1.time }
        let sortedTemperature = temperatures.sorted { $0.time < $1.time }

        let first = min(sortedCapacity.first?.time ?? .distantFuture, sortedTemperature.first?.time ?? .distantFuture)
        let last = max(sortedCapacity.last?.time ?? .distantPast, sortedTemperature.last?.time ?? .distantPast)

        return PowerlogSummary(
            table: table,
            matchedColumns: selected.compactMap { mapping[$0] },
            rowCount: rows.count,
            candidateTables: candidateCount,
            cycleCount: cycleCount,
            designCapacity: designCapacity,
            maxCapacity: maxCapacity,
            latestTemperature: latestTemperature,
            latestVoltage: latestVoltage,
            firstSample: first == .distantFuture ? nil : first,
            lastSample: last == .distantPast ? nil : last,
            capacitySeries: downsample(sortedCapacity, limit: 90),
            capacityUnit: design == nil ? "mAh" : "%",
            temperatureSeries: downsample(sortedTemperature, limit: 90)
        )
    }

    // MARK: - 单位换算

    /// Powerlog 里的时间戳有 Unix 秒、毫秒、Apple 纪元三种写法，按结果是否落在合理区间判断。
    static func decodeDate(_ raw: Double) -> Date? {
        guard raw.isFinite, raw > 0 else { return nil }
        var seconds = raw
        if seconds > 1e12 { seconds /= 1000 }
        if seconds > 4e9 { return nil }

        let now = Date()
        let floor = Date(timeIntervalSince1970: 1_420_070_400) // 2015-01-01
        for candidate in [seconds, seconds + 978_307_200] {
            let date = Date(timeIntervalSince1970: candidate)
            if date > floor, date < now.addingTimeInterval(86_400 * 2) {
                return date
            }
        }
        return nil
    }

    /// 温度有 0.1K、0.01°C、0.1°C、已经是°C 四种可能写法，
    /// 取落在 0–60 且最接近 32 的那一档——电池工作温度几乎不会离这个中心太远。
    static func decodeCelsius(_ raw: Double) -> Double? {
        guard raw.isFinite else { return nil }
        let candidates = [raw / 100, raw / 10, raw].filter { $0 >= -10 && $0 <= 70 }
        guard !candidates.isEmpty else { return nil }
        return candidates.min { abs($0 - 32) < abs($1 - 32) }
    }

    static func decodeVolts(_ raw: Double) -> Double? {
        guard raw.isFinite else { return nil }
        let volts = raw > 20 ? raw / 1000 : raw
        return (2.5...5.5).contains(volts) ? volts : nil
    }

    // MARK: - SQLite 封装

    private static func tableNames(_ db: OpaquePointer) -> [String] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type = 'table'", -1, &statement, nil) == SQLITE_OK,
              let statement else { return [] }
        defer { sqlite3_finalize(statement) }

        var names: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 0) {
                names.append(String(cString: text))
            }
        }
        return names
    }

    private static func columnsOf(_ db: OpaquePointer, table: String) -> [String] {
        var statement: OpaquePointer?
        let sql = "PRAGMA table_info(\(quote(table)))"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return [] }
        defer { sqlite3_finalize(statement) }

        var names: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 1) {
                names.append(String(cString: text))
            }
        }
        return names
    }

    private static func mapRoles(_ columns: [String]) -> [Role: String] {
        var mapping: [Role: String] = [:]
        for column in columns {
            let normalized = column.lowercased().filter { $0.isLetter || $0.isNumber }
            for (role, names) in aliases where names.contains(normalized) {
                if mapping[role] == nil { mapping[role] = column }
            }
        }
        return mapping
    }

    private static func scoreOf(_ mapping: [Role: String]) -> Int {
        var score = 0
        if mapping[.cycleCount] != nil { score += 4 }
        if mapping[.maxCapacity] != nil { score += 3 }
        if mapping[.designCapacity] != nil { score += 3 }
        if mapping[.temperature] != nil { score += 2 }
        if mapping[.currentCapacity] != nil { score += 1 }
        if mapping[.voltage] != nil { score += 1 }
        return score
    }

    private static func query(_ db: OpaquePointer, _ sql: String) -> [[String: Double]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return [] }
        defer { sqlite3_finalize(statement) }

        let count = Int(sqlite3_column_count(statement))
        var names: [String] = []
        for index in 0..<count {
            names.append(String(cString: sqlite3_column_name(statement, Int32(index))))
        }

        var rows: [[String: Double]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            var row: [String: Double] = [:]
            for index in 0..<count where sqlite3_column_type(statement, Int32(index)) != SQLITE_NULL {
                row[names[index]] = sqlite3_column_double(statement, Int32(index))
            }
            rows.append(row)
        }
        return rows
    }

    private static func quote(_ identifier: String) -> String {
        "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: - 抽稀

    /// 曲线只需要形状，不需要每一行。等间隔抽到 limit 个点，保留首尾。
    private static func downsample(_ points: [PowerlogSummary.Point], limit: Int) -> [PowerlogSummary.Point] {
        guard points.count > limit, limit > 2 else { return points }
        let step = Double(points.count - 1) / Double(limit - 1)
        var result: [PowerlogSummary.Point] = []
        result.reserveCapacity(limit)
        for index in 0..<limit {
            let position = Int((Double(index) * step).rounded())
            result.append(points[min(position, points.count - 1)])
        }
        return result
    }
}
