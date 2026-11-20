import Foundation
import Observation

// MARK: - 观测

/// 一次「充进去多少 mAh / 电量涨了多少」的观测。
///
/// 这是本机唯一能拿到的、接近真实的容量信息：不读系统日志，也不依赖任何
/// 私有数据库，只用电池端电流对时间积分，再除以这段充电带来的 SOC 变化。
/// 单次结果受 SOC 量化（1%）和温度影响，所以要多攒几次取中位数。
struct CapacityObservation: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    let time: Date
    let milliampHours: Double
    let deltaLevel: Double

    var capacityMah: Double {
        guard deltaLevel > 0.01 else { return 0 }
        return milliampHours / deltaLevel
    }
}

/// 一天的聚合。只存统计量，不存原始采样点 —— 400 天也就几十 KB。
struct DailyBatteryRecord: Codable, Hashable, Sendable, Identifiable {
    var id: String { dayKey }

    /// 本地时区的 "yyyy-MM-dd"
    let dayKey: String
    var sampleCount: Int
    var levelMin: Double?
    var levelMax: Double?
    var batteryTempMin: Double?
    var batteryTempMax: Double?
    var chargerTempMax: Double?
    var chargingSeconds: Double
    var pluggedSeconds: Double
    var chargedMilliampHours: Double
    var chargedWattHours: Double
    var peakWatts: Double
    var plugEvents: Int

    init(dayKey: String) {
        self.dayKey = dayKey
        sampleCount = 0
        levelMin = nil
        levelMax = nil
        batteryTempMin = nil
        batteryTempMax = nil
        chargerTempMax = nil
        chargingSeconds = 0
        pluggedSeconds = 0
        chargedMilliampHours = 0
        chargedWattHours = 0
        peakWatts = 0
        plugEvents = 0
    }

    enum CodingKeys: String, CodingKey {
        case dayKey, sampleCount, levelMin, levelMax
        case batteryTempMin, batteryTempMax, chargerTempMax
        case chargingSeconds, pluggedSeconds
        case chargedMilliampHours, chargedWattHours, peakWatts, plugEvents
    }

    /// 手写解码：以后加字段时，旧历史文件缺 key 也能读，不会整份作废。
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        dayKey = try box.decode(String.self, forKey: .dayKey)
        sampleCount = try box.decodeIfPresent(Int.self, forKey: .sampleCount) ?? 0
        levelMin = try box.decodeIfPresent(Double.self, forKey: .levelMin)
        levelMax = try box.decodeIfPresent(Double.self, forKey: .levelMax)
        batteryTempMin = try box.decodeIfPresent(Double.self, forKey: .batteryTempMin)
        batteryTempMax = try box.decodeIfPresent(Double.self, forKey: .batteryTempMax)
        chargerTempMax = try box.decodeIfPresent(Double.self, forKey: .chargerTempMax)
        chargingSeconds = try box.decodeIfPresent(Double.self, forKey: .chargingSeconds) ?? 0
        pluggedSeconds = try box.decodeIfPresent(Double.self, forKey: .pluggedSeconds) ?? 0
        chargedMilliampHours = try box.decodeIfPresent(Double.self, forKey: .chargedMilliampHours) ?? 0
        chargedWattHours = try box.decodeIfPresent(Double.self, forKey: .chargedWattHours) ?? 0
        peakWatts = try box.decodeIfPresent(Double.self, forKey: .peakWatts) ?? 0
        plugEvents = try box.decodeIfPresent(Int.self, forKey: .plugEvents) ?? 0
    }
}

/// 正在进行的充电片段。不落盘：App 重启后积分会断档，接着算只会得到错数。
struct PendingChargeSegment: Hashable, Sendable {
    var startTime: Date
    var startLevel: Double
    var milliampHours: Double
    var lastTime: Date
}

struct CapacityEstimate: Hashable, Sendable {
    let milliampereHours: Double
    let sampleCount: Int
}

// MARK: - 存储

/// 本机自建电池历史。
///
/// 存在理由：iOS 不向第三方 App 开放循环次数与健康度，系统 Powerlog 又躺在
/// 沙盒外读不到。唯一完全合法、无需任何导入的路径，是自己长期记录：
/// 实时采样 → 每日聚合 → 从充电片段反推实际容量。
///
/// 代价是历史从安装那天开始；想要安装前的数据，仍然可以导入诊断档案（可选）。
@MainActor
@Observable
final class BatteryHistoryStore {

    static let shared = BatteryHistoryStore()

    private(set) var records: [DailyBatteryRecord] = []
    private(set) var observations: [CapacityObservation] = []
    private(set) var pending: PendingChargeSegment?

    /// 上限：一年多。再多也没有展示意义，还会拖慢解码。
    private static let maxDays = 400
    private static let maxObservations = 200

    /// 采样断档超过这个秒数，本次积分视为不可信，直接丢弃。
    private static let maxGap: TimeInterval = 180
    /// SOC 变化小于 15% 的片段误差太大，不用于估算容量。
    private static let minimumDeltaLevel = 0.15
    private static let minimumMilliampHours = 50.0
    private static let minimumDuration: TimeInterval = 5 * 60
    private static let maximumDuration: TimeInterval = 8 * 3600

    private let directory: URL
    private let fileURL: URL
    private let dayFormatter: DateFormatter
    private var lastState: ChargeSample.ChargeState = .unknown
    private var dirty = false
    private var writesSinceFlush = 0

    init(directory: URL? = nil, calendar: Calendar = .current) {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("iDeviceXRay", isDirectory: true)
        self.directory = base
        self.fileURL = base.appendingPathComponent("battery-history.json")

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        self.dayFormatter = formatter

        load()
    }

    // MARK: 写入

    /// 每次采样调用一次。`dt` 是距上一次采样的秒数。
    func ingest(_ sample: ChargeSample, dt: TimeInterval) {
        guard dt.isFinite, dt >= 0, sample.time.timeIntervalSince1970 > 0 else { return }
        let step = min(dt, 30)
        let key = dayKey(for: sample.time)
        var record = records.first(where: { $0.dayKey == key }) ?? DailyBatteryRecord(dayKey: key)

        record.sampleCount += 1

        if let level = sample.level, (0...1).contains(level) {
            record.levelMin = min(record.levelMin ?? level, level)
            record.levelMax = max(record.levelMax ?? level, level)
        }

        if let temperature = sample.batteryTemperature, (-40...150).contains(temperature) {
            record.batteryTempMin = min(record.batteryTempMin ?? temperature, temperature)
            record.batteryTempMax = max(record.batteryTempMax ?? temperature, temperature)
        }

        if let temperature = sample.chargerTemperature, (-40...150).contains(temperature) {
            record.chargerTempMax = max(record.chargerTempMax ?? temperature, temperature)
        }

        switch sample.state {
        case .charging:
            record.chargingSeconds += step
            record.pluggedSeconds += step
        case .full, .plugged:
            record.pluggedSeconds += step
        default:
            break
        }

        if sample.state != .unplugged, sample.state != .unknown,
           lastState == .unplugged || lastState == .unknown {
            record.plugEvents += 1
        }
        lastState = sample.state

        if sample.state == .charging,
           let current = sample.batteryCurrent,
           abs(current) > 0.05, step > 0 {
            record.chargedMilliampHours += abs(current) * 1000 * step / 3600
            if let watts = sample.batteryWatts, watts > 0 {
                record.chargedWattHours += watts * step / 3600
                record.peakWatts = max(record.peakWatts, watts)
            }
        }

        advanceSegment(sample, dt: step)
        store(record, for: key)
        markDirty()
    }

    /// 写入失败重试、进后台前调用，保证不丢太多。
    func flush() {
        guard dirty else { return }
        write()
    }

    func reset() {
        records = []
        observations = []
        pending = nil
        dirty = false
        writesSinceFlush = 0
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: 充电片段

    /// 只认「持续充电 + 电流够大 + 电量单调上升」的片段。
    /// 中途拔线、后台挂起留下的空洞都会让片段作废 —— 宁可没有数，也不给错数。
    private func advanceSegment(_ sample: ChargeSample, dt: TimeInterval) {
        if let pending, sample.time.timeIntervalSince(pending.lastTime) > Self.maxGap {
            self.pending = nil
        }

        let isCharging = sample.state == .charging
            && (sample.batteryCurrent.map { abs($0) > 0.05 } ?? false)
            && sample.level != nil

        guard isCharging, let level = sample.level, let current = sample.batteryCurrent else {
            if pending != nil { settle(at: sample.time, endLevel: sample.level) }
            return
        }

        let delta = abs(current) * 1000 * dt / 3600

        if var segment = pending, level + 0.01 >= segment.startLevel {
            segment.milliampHours += delta
            segment.lastTime = sample.time
            pending = segment

            let tooLong = sample.time.timeIntervalSince(segment.startTime) > Self.maximumDuration
            if level >= 0.999 || tooLong {
                settle(at: sample.time, endLevel: level)
            }
        } else {
            if pending != nil { settle(at: sample.time, endLevel: level) }
            pending = PendingChargeSegment(
                startTime: sample.time,
                startLevel: level,
                milliampHours: delta,
                lastTime: sample.time
            )
        }
    }

    private func settle(at time: Date, endLevel: Double?) {
        guard let segment = pending else { return }
        pending = nil

        guard let endLevel else { return }
        let deltaLevel = endLevel - segment.startLevel
        let duration = time.timeIntervalSince(segment.startTime)

        guard deltaLevel >= Self.minimumDeltaLevel,
              segment.milliampHours >= Self.minimumMilliampHours,
              duration >= Self.minimumDuration,
              duration <= Self.maximumDuration else { return }

        let capacity = segment.milliampHours / deltaLevel
        guard capacity.isFinite, (300...25_000).contains(capacity) else { return }

        observations.append(CapacityObservation(
            id: UUID(),
            time: time,
            milliampHours: segment.milliampHours,
            deltaLevel: deltaLevel
        ))
        if observations.count > Self.maxObservations {
            observations.removeFirst(observations.count - Self.maxObservations)
        }
        markDirty()
    }

    // MARK: 派生

    var firstRecordDate: Date? {
        records.first.flatMap { dayFormatter.date(from: $0.dayKey) }
    }

    var recordedDayCount: Int { records.count }

    func recentDays(_ count: Int) -> [DailyBatteryRecord] {
        Array(records.suffix(max(0, count)))
    }

    var today: DailyBatteryRecord? {
        records.first { $0.dayKey == dayKey(for: Date()) }
    }

    /// 最近 20 次观测的中位数。平均值会被「充到一半拔线」的片段带偏。
    var capacityEstimate: CapacityEstimate? {
        let values = observations.suffix(20)
            .map(\.capacityMah)
            .filter { $0.isFinite && $0 > 0 }
        guard !values.isEmpty else { return nil }
        return CapacityEstimate(milliampereHours: Self.median(values), sampleCount: values.count)
    }

    /// 与设计容量的比值。只做展示，不做「电池是否需要更换」的判断 —— 那是系统的结论。
    func healthPercent(designMah: Int?) -> Double? {
        guard let designMah, designMah > 0, let estimate = capacityEstimate else { return nil }
        let percent = estimate.milliampereHours / Double(designMah) * 100
        guard percent.isFinite, (30...130).contains(percent) else { return nil }
        return percent
    }

    /// 近 N 天里最高的电池温度。没有传感器时返回 nil，不补 0。
    func peakTemperature(days: Int) -> Double? {
        recentDays(days).compactMap(\.batteryTempMax).max()
    }

    /// 近 N 天累计充电时长（小时）
    func chargingHours(days: Int) -> Double {
        recentDays(days).reduce(0) { $0 + $1.chargingSeconds } / 3600
    }

    // MARK: 私有

    private func dayKey(for date: Date) -> String {
        dayFormatter.string(from: date)
    }

    private func store(_ record: DailyBatteryRecord, for key: String) {
        if let index = records.firstIndex(where: { $0.dayKey == key }) {
            records[index] = record
        } else {
            records.append(record)
            records.sort { $0.dayKey < $1.dayKey }
            if records.count > Self.maxDays {
                records.removeFirst(records.count - Self.maxDays)
            }
        }
    }

    private func markDirty() {
        dirty = true
        writesSinceFlush += 1
        // 1 秒间隔下约 40 秒落一次盘；文件只有几十 KB，不必每 tick 都写。
        if writesSinceFlush >= 40 { write() }
    }

    private struct Payload: Codable {
        var version: Int
        var records: [DailyBatteryRecord]
        var observations: [CapacityObservation]
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return }
        records = payload.records.sorted { $0.dayKey < $1.dayKey }
        observations = payload.observations
    }

    private func write() {
        let payload = Payload(version: 1, records: records, observations: observations)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
            dirty = false
            writesSinceFlush = 0
        } catch {
            // 落盘失败不影响采样，下一个周期再试。
        }
    }

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }
}
