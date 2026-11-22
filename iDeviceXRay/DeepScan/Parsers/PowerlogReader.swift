import Foundation
import SQLite3

/// 读取 Powerlog 数据库（`powerlog_*.PLSQL` / `CurrentPowerlog.PLSQL`）。
///
/// 三条原则，都是被真机回包打出来的：
///
/// 1. **不假设表名**。iOS 26/27 起主库文件名从 `CurrentPowerlog.PLSQL` 改成
///    `powerlog_2026-11-20_09-08_XXXX.PLSQL`，表名同样会变。这里先按名字分层
///    （PLBatteryAgent → 含 battery → 含 charger / energy），全部落空时再退到
///    SMC / 热相关表，绝不因为一个前缀对不上就放弃。
/// 2. **不假设列名**。`AppleRawMaxCapacity`、`RawMaxCapacity`、`MaxCapacity`
///    在不同代际里都出现过，用「归一化后包含」加权匹配，而不是精确相等。
/// 3. **跨表取数**。循环次数常常不在容量表里，而在 `..._UpdateBatteryInfo`
///    之类的表；只挑一张「最像」的表，就会拿到半份数据。这里每张候选表都读，
///    标量取时间最新的一份，曲线取点最多的一份。
///
/// 解不出来就返回 nil，并把「检查了哪些表、各有哪些列」写进 notes，交给界面
/// 和报告展示——猜一个数比空着更糟。
enum PowerlogReader {

    struct Outcome {
        var summary: PowerlogSummary?
        var notes: [String] = []
    }

    /// 单表最多取多少行。60 秒一条的话 1.2 万行约等于 8 天，够画形状。
    /// 六张表同时进内存，行数再大就只是浪费。
    private static let maxRowsPerTable = 12_000
    private static let maxTablesToRead = 6
    private static let maxTablesToInspect = 240

    // MARK: - 列角色

    private enum Role: Hashable, CaseIterable {
        case timestamp, cycleCount, designCapacity, maxCapacity, currentCapacity
        case temperature, voltage, amperage

        var weight: Int {
            switch self {
            case .timestamp: return 0
            case .cycleCount: return 6
            case .designCapacity, .maxCapacity: return 4
            case .temperature: return 3
            case .currentCapacity: return 2
            case .voltage, .amperage: return 1
            }
        }
    }

    /// 归一化（小写、只留字母数字）之后按「包含」匹配，取权重最高的一列。
    /// 权重差就是为了解决 `AppleRawMaxCapacity` 和 `MaxCapacity` 同时存在时选错。
    private static let rolePatterns: [Role: [(needle: String, weight: Int)]] = [
        .timestamp: [("timestamp", 10), ("unixtime", 8), ("time", 3)],
        .cycleCount: [("cyclecount", 10), ("cycle", 4)],
        .designCapacity: [
            ("designcapacity", 10), ("nominalchargecapacity", 9),
            ("designcap", 8), ("nominalcapacity", 6)
        ],
        .maxCapacity: [
            ("applerawmaxcapacity", 12), ("rawmaxcapacity", 11),
            ("applemaxcapacity", 9), ("maxcapacity", 8), ("fullchargecapacity", 7)
        ],
        .currentCapacity: [
            ("applerawcurrentcapacity", 12), ("rawcurrentcapacity", 11),
            ("applecurrentcapacity", 9), ("currentcapacity", 8), ("remainingcapacity", 7)
        ],
        .temperature: [("batterytemperature", 12), ("temperature", 10)],
        .voltage: [("batteryvoltage", 12), ("voltage", 10)],
        .amperage: [("instantamperage", 12), ("amperage", 10)]
    ]

    private struct Plan {
        let table: String
        let mapping: [Role: String]
        let score: Int
    }

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

        let allTables = tableNames(db)
        let candidates = candidateTables(allTables)
        guard !candidates.isEmpty else {
            outcome.notes.append("Powerlog 已打开（\(allTables.count) 张表），其中没有电池相关表，历史不可用")
            return outcome
        }

        var plans: [Plan] = []
        for candidate in candidates {
            let columns = columnsOf(db, table: candidate.name)
            guard !columns.isEmpty else { continue }
            let mapping = pickColumns(columns)
            guard mapping[.timestamp] != nil, mapping.count > 1 else { continue }

            var score = candidate.tier / 10
            for role in Role.allCases where mapping[role] != nil {
                score += role.weight
            }
            plans.append(Plan(table: candidate.name, mapping: mapping, score: score))
        }

        guard !plans.isEmpty else {
            outcome.notes.append(diagnose(db, candidates: candidates))
            return outcome
        }

        // 分高的先读：PLBatteryAgent 主表排在前面，SMC / 热表兜底
        plans.sort { $0.score > $1.score }
        let chosen = Array(plans.prefix(maxTablesToRead))

        var loaded: [(plan: Plan, rows: [[String: Double]])] = []
        for plan in chosen {
            let rows = query(db, sql: selectSQL(for: plan), limit: maxRowsPerTable)
            guard !rows.isEmpty else { continue }
            loaded.append((plan, rows))
        }

        guard !loaded.isEmpty else {
            outcome.notes.append("Powerlog 里 \(chosen.count) 张候选表都读不出数据（可能被加密或为空）")
            return outcome
        }

        let summary = summarize(loaded: loaded, candidateCount: candidates.count)
        outcome.summary = summary
        if summary == nil {
            outcome.notes.append(diagnose(db, candidates: candidates))
        }
        return outcome
    }

    // MARK: - 汇总

    private static func summarize(
        loaded: [(plan: Plan, rows: [[String: Double]])],
        candidateCount: Int
    ) -> PowerlogSummary? {
        var cycle: (value: Int, date: Date)?
        var design: (value: Int, date: Date)?
        var maxCapacity: (value: Int, date: Date)?
        var latestTemperature: (value: Double, date: Date)?
        var latestVoltage: (value: Double, date: Date)?
        var rowCount = 0
        var matched: [String] = []

        for item in loaded {
            rowCount += item.rows.count
            let mapping = item.plan.mapping
            matched.append(contentsOf: Role.allCases.compactMap { role in
                mapping[role].map { "\(item.plan.table).\($0)" }
            })

            // 行按时间倒序取回，第一行有效值就是最新；跨表比较日期取更近的一份
            for row in item.rows {
                guard let rawTime = row[mapping[.timestamp] ?? ""], let date = decodeDate(rawTime) else { continue }

                if let column = mapping[.cycleCount], let value = row[column], value > 0, value < 5_000 {
                    if cycle == nil || date > cycle!.date { cycle = (Int(value), date) }
                }
                if let column = mapping[.designCapacity], let value = row[column], value > 100, value < 20_000 {
                    if design == nil || date > design!.date { design = (Int(value), date) }
                }
                if let column = mapping[.maxCapacity], let value = row[column], value > 100, value < 20_000 {
                    if maxCapacity == nil || date > maxCapacity!.date { maxCapacity = (Int(value), date) }
                }
                if let column = mapping[.temperature], let value = row[column], let celsius = decodeCelsius(value) {
                    if latestTemperature == nil || date > latestTemperature!.date { latestTemperature = (celsius, date) }
                }
                if let column = mapping[.voltage], let value = row[column], let volts = decodeVolts(value) {
                    if latestVoltage == nil || date > latestVoltage!.date { latestVoltage = (volts, date) }
                }
            }
        }

        // 曲线整段来自同一张表：不同表的量纲和采样频率都不一样，拼起来会骗人
        var capacityPoints: [PowerlogSummary.Point] = []
        var temperaturePoints: [PowerlogSummary.Point] = []
        var capacityUnit = "mAh"
        var dominantTable = loaded[0].plan.table
        var dominantFields = -1

        for item in loaded {
            let mapping = item.plan.mapping
            var fields = 0
            for role in Role.allCases where mapping[role] != nil && role != .timestamp { fields += 1 }
            if fields > dominantFields {
                dominantFields = fields
                dominantTable = item.plan.table
            }

            var points: [PowerlogSummary.Point] = []
            for row in item.rows {
                guard let rawTime = row[mapping[.timestamp] ?? ""], let date = decodeDate(rawTime) else { continue }

                if let column = mapping[.maxCapacity], let value = row[column], value > 100, value < 20_000 {
                    if let design, design.value > 0 {
                        let percent = value / Double(design.value) * 100
                        if (25...130).contains(percent) { points.append(.init(time: date, value: percent)) }
                    } else {
                        points.append(.init(time: date, value: value))
                    }
                } else if let column = mapping[.currentCapacity], let value = row[column], value > 100, value < 20_000,
                          let max = maxCapacity?.value, max > 0 {
                    let percent = value / Double(max) * 100
                    if (0...110).contains(percent) { points.append(.init(time: date, value: percent)) }
                }
            }

            if points.count > capacityPoints.count {
                capacityPoints = points
                capacityUnit = design == nil ? "mAh" : "%"
            }

            var temperatures: [PowerlogSummary.Point] = []
            for row in item.rows {
                guard let rawTime = row[mapping[.timestamp] ?? ""], let date = decodeDate(rawTime) else { continue }
                if let column = mapping[.temperature], let value = row[column], let celsius = decodeCelsius(value) {
                    temperatures.append(.init(time: date, value: celsius))
                }
            }
            if temperatures.count > temperaturePoints.count {
                temperaturePoints = temperatures
            }
        }

        let sortedCapacity = capacityPoints.sorted { $0.time < $1.time }
        let sortedTemperature = temperaturePoints.sorted { $0.time < $1.time }

        let hasScalar = cycle != nil || design != nil || maxCapacity != nil
            || latestTemperature != nil || latestVoltage != nil
        guard hasScalar || !sortedCapacity.isEmpty || !sortedTemperature.isEmpty else {
            return nil
        }

        let first = min(sortedCapacity.first?.time ?? .distantFuture, sortedTemperature.first?.time ?? .distantFuture)
        let last = max(sortedCapacity.last?.time ?? .distantPast, sortedTemperature.last?.time ?? .distantPast)

        var seenColumns = Set<String>()
        let uniqueColumns = matched.filter { seenColumns.insert($0).inserted }

        return PowerlogSummary(
            table: loaded.count > 1 ? "\(dominantTable) +\(loaded.count - 1)" : dominantTable,
            matchedColumns: Array(uniqueColumns.prefix(12)),
            rowCount: rowCount,
            candidateTables: candidateCount,
            cycleCount: cycle?.value,
            designCapacity: design?.value,
            maxCapacity: maxCapacity?.value,
            latestTemperature: latestTemperature?.value,
            latestVoltage: latestVoltage?.value,
            firstSample: first == .distantFuture ? nil : first,
            lastSample: last == .distantPast ? nil : last,
            capacitySeries: downsample(sortedCapacity, limit: 90),
            capacityUnit: capacityUnit,
            temperatureSeries: downsample(sortedTemperature, limit: 90)
        )
    }

    // MARK: - 表与列

    private static func candidateTables(_ names: [String]) -> [(name: String, tier: Int)] {
        var result: [(name: String, tier: Int)] = []

        for name in names {
            let lower = name.lowercased()
            if lower.hasPrefix("plbatteryagent") {
                result.append((name, 100))
            } else if lower.contains("battery") {
                result.append((name, 80))
            } else if lower.contains("powerlog") || lower.contains("charger") || lower.contains("charging") {
                result.append((name, 40))
            } else if lower.contains("energy") || lower.contains("smc") || lower.contains("thermal") {
                result.append((name, 20))
            }
        }

        // 同层里短名通常才是主表，子表（_EventBackward_...）排在后面
        result.sort { lhs, rhs in
            if lhs.tier != rhs.tier { return lhs.tier > rhs.tier }
            return lhs.name.count < rhs.name.count
        }
        return Array(result.prefix(maxTablesToInspect))
    }

    private static func pickColumns(_ columns: [String]) -> [Role: String] {
        var best: [Role: (column: String, score: Int)] = [:]

        for column in columns {
            let normalized = column.lowercased().filter { $0.isLetter || $0.isNumber }
            guard !normalized.isEmpty else { continue }

            for (role, patterns) in rolePatterns {
                var score = 0
                for pattern in patterns where normalized.contains(pattern.needle) {
                    score = max(score, pattern.weight)
                }
                guard score > 0 else { continue }
                if score > (best[role]?.score ?? 0) {
                    best[role] = (column, score)
                }
            }
        }

        return best.mapValues { $0.column }
    }

    private static func selectSQL(for plan: Plan) -> String {
        var roles: [Role] = [.timestamp]
        roles.append(contentsOf: Role.allCases.filter { $0 != .timestamp && plan.mapping[$0] != nil })

        let columnList = roles.compactMap { plan.mapping[$0] }.map { quote($0) }.joined(separator: ", ")
        let order = quote(plan.mapping[.timestamp] ?? "timestamp")
        return "SELECT \(columnList) FROM \(quote(plan.table)) ORDER BY \(order) DESC LIMIT \(maxRowsPerTable)"
    }

    /// 全盘失败时把结构摊开：表名 + 前几列。用户把这段发过来就能直接定位。
    private static func diagnose(_ db: OpaquePointer, candidates: [(name: String, tier: Int)]) -> String {
        let sample = candidates.prefix(4).map { candidate -> String in
            let columns = columnsOf(db, table: candidate.name).prefix(8).joined(separator: ",")
            return "\(candidate.name)(\(columns))"
        }
        return "找到 \(candidates.count) 张电池相关表，但没有一张带可用时间戳列。候选：\(sample.joined(separator: "；"))"
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

    private static func query(_ db: OpaquePointer, sql: String, limit: Int) -> [[String: Double]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return [] }
        defer { sqlite3_finalize(statement) }

        let count = Int(sqlite3_column_count(statement))
        var names: [String] = []
        for index in 0..<count {
            names.append(String(cString: sqlite3_column_name(statement, Int32(index))))
        }

        var rows: [[String: Double]] = []
        while sqlite3_step(statement) == SQLITE_ROW, rows.count < limit {
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
