import Foundation
import Observation
import UIKit

// MARK: - 采样点

/// 曲线上的一次采样。和 `ReportField` 分开：报告是某一刻的存档，
/// 这里是随时间变化的点，不进存档、不参与评分。
struct ChargeSample: Identifiable, Hashable, Sendable {

    enum ChargeState: String, Hashable, Sendable {
        case charging
        case full
        case plugged
        case unplugged
        case unknown

        var title: String {
            switch self {
            case .charging: return "充电中"
            case .full: return "已充满"
            case .plugged: return "已连接电源"
            case .unplugged: return "使用电池"
            case .unknown: return "状态未知"
            }
        }
    }

    let id: Int
    let time: Date

    /// 输入端（USB-C 口），未插电时为 nil 而不是 0
    let inputVoltage: Double?
    let inputCurrent: Double?
    let inputWatts: Double?

    /// 电池端（SMC VP0u / IQ0B）
    let batteryVoltage: Double?
    /// 有符号：正为充入，负为放出
    let batteryCurrent: Double?
    let batteryWatts: Double?

    let batteryTemperature: Double?
    let chargerTemperature: Double?
    let socTemperature: Double?

    /// 0…1
    let level: Double?
    let state: ChargeState
    let adapterName: String?
    let adapterRatedWatts: Double?

    var batteryCurrentMagnitude: Double? { batteryCurrent.map(abs) }
}

// MARK: - 统计

struct ChargeStats: Equatable, Sendable {
    var minimum: Double?
    var maximum: Double?
    var average: Double?
    var count: Int

    static let empty = ChargeStats(minimum: nil, maximum: nil, average: nil, count: 0)

    static func make(_ values: [Double]) -> ChargeStats {
        guard !values.isEmpty else { return .empty }
        let sorted = values.sorted()
        let sum = values.reduce(0, +)
        return ChargeStats(
            minimum: sorted.first,
            maximum: sorted.last,
            average: sum / Double(values.count),
            count: values.count
        )
    }
}

// MARK: - 图表指标

enum ChargeMetric: String, CaseIterable, Hashable, Sendable {
    case power
    case current
    case temperature

    var title: String {
        switch self {
        case .power: return "功率"
        case .current: return "电流"
        case .temperature: return "温度"
        }
    }

    var unit: String {
        switch self {
        case .power: return "W"
        case .current: return "A"
        case .temperature: return "°C"
        }
    }

    /// 每个指标都有主用测点与备用测点。没有值就返回 nil，由图表断开，
    /// 不用 0 填补 —— 0 W 和「没有传感器」是两件事。
    func value(_ sample: ChargeSample) -> Double? {
        switch self {
        case .power:
            return sample.inputWatts ?? sample.batteryWatts
        case .current:
            return sample.inputCurrent ?? sample.batteryCurrentMagnitude
        case .temperature:
            return sample.chargerTemperature ?? sample.batteryTemperature ?? sample.socTemperature
        }
    }
}

// MARK: - 实时监控

/// 充电链路的持续采样器。
///
/// 为什么做成共享单例：HID client 全进程只能有一个，页面各自起一个轮询时，
/// 读数会互相干扰并拿到 NaN。这里把「谁在用」记成一组 token，最后一个退出
/// 才停表；同时只有一条采样循环，间隔取用户设置。
@MainActor
@Observable
final class ChargeMonitor {

    static let shared = ChargeMonitor()

    /// 可选刷新间隔（秒）。0.5 秒对 HID 而言偏激进，1 秒已经足够看出插拔与功率爬升。
    static let intervalOptions: [TimeInterval] = [1, 2, 5]

    /// 300 个点 ≈ 1 秒间隔下 5 分钟，够画曲线又不至于吃内存。
    private static let historyLimit = 300
    private static let intervalKey = "charge.refreshInterval"

    private(set) var samples: [ChargeSample] = []
    private(set) var snapshot: EnergySnapshot = .empty
    private(set) var isSampling = false
    private(set) var isPaused = false
    private(set) var lastUpdate: Date?
    /// HID 不可用的次数：用来区分「没插电」和「接口被系统关了」
    private(set) var hidFailures = 0
    private(set) var sampleCount = 0

    private(set) var sessionStart: Date?
    private(set) var sessionMilliampHours: Double = 0
    private(set) var sessionWattHours: Double = 0
    private(set) var sessionPeakWatts: Double = 0

    var refreshInterval: TimeInterval {
        didSet {
            guard refreshInterval != oldValue else { return }
            UserDefaults.standard.set(refreshInterval, forKey: Self.intervalKey)
            if task != nil {
                stopTask()
                launchIfNeeded()
            }
        }
    }

    private var holders: Set<String> = []
    private var task: Task<Void, Never>?
    private var isForeground = true
    private var sequence = 0
    private var previousTick: Date?

    private init() {
        let saved = UserDefaults.standard.double(forKey: Self.intervalKey)
        refreshInterval = Self.intervalOptions.contains(saved) ? saved : 1
    }

    // MARK: 派生值

    var latest: ChargeSample? { samples.last }

    var isConnected: Bool { snapshot.power.externalConnected }

    var isCharging: Bool { snapshot.power.charging }

    var sessionDuration: TimeInterval {
        guard let sessionStart else { return 0 }
        return Date().timeIntervalSince(sessionStart)
    }

    /// 最近 N 秒的采样点，结束时间以最后一个点为准，避免「停止采样后窗口全空」。
    func recentSamples(within seconds: TimeInterval) -> [ChargeSample] {
        guard let last = samples.last else { return [] }
        let cutoff = last.time.addingTimeInterval(-seconds)
        return samples.filter { $0.time >= cutoff }
    }

    func stats(_ metric: ChargeMetric, seconds: TimeInterval = 60) -> ChargeStats {
        ChargeStats.make(recentSamples(within: seconds).compactMap { metric.value($0) })
    }

    // MARK: 生命周期

    /// 用 token 登记使用方，重复登记不会叠加。
    func begin(_ token: String) {
        holders.insert(token)
        launchIfNeeded()
    }

    func end(_ token: String) {
        holders.remove(token)
        if holders.isEmpty { stopTask() }
    }

    func pause() {
        isPaused = true
        stopTask()
        BatteryHistoryStore.shared.flush()
    }

    func resume() {
        isPaused = false
        launchIfNeeded()
    }

    /// App 进后台时挂起采样，回前台自动续上，采样历史不清空。
    func setForeground(_ value: Bool) {
        guard isForeground != value else { return }
        isForeground = value
        if value {
            launchIfNeeded()
        } else {
            stopTask()
            BatteryHistoryStore.shared.flush()
        }
    }

    func resetSession() {
        sessionStart = nil
        sessionMilliampHours = 0
        sessionWattHours = 0
        sessionPeakWatts = 0
    }

    // MARK: 采样循环

    private func launchIfNeeded() {
        guard task == nil, isForeground, !isPaused, !holders.isEmpty else { return }
        isSampling = true
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.tick()
                guard !Task.isCancelled else { return }
                let interval = self.refreshInterval
                try? await Task.sleep(nanoseconds: UInt64(max(0.5, interval) * 1_000_000_000))
            }
        }
    }

    private func stopTask() {
        task?.cancel()
        task = nil
        isSampling = false
        previousTick = nil
    }

    private func tick() async {
        let raw = await SensorProbe.shared.snapshot()
        guard !Task.isCancelled else { return }
        apply(raw)
    }

    private func apply(_ raw: EnergySnapshot) {
        var snap = raw

        // 电量只能从 UIDevice 读，且必须在主线程
        let device = UIDevice.current
        if !device.isBatteryMonitoringEnabled {
            device.isBatteryMonitoringEnabled = true
        }
        let level = device.batteryLevel
        snap.batteryLevel = level >= 0 ? Double(level) : nil

        snapshot = snap
        if !snap.hidAvailable { hidFailures += 1 }

        let now = Date()
        // 后台挂起或主线程卡顿会让间隔变长，截断到 4 个周期，避免把一次长间隔
        // 当成「持续大电流」积进容量。
        let dt = previousTick.map { min(max(now.timeIntervalSince($0), 0), refreshInterval * 4) } ?? 0
        previousTick = now

        sequence += 1
        sampleCount += 1

        let power = snap.power
        let state: ChargeSample.ChargeState
        if power.charging {
            state = .charging
        } else if power.fullCharge {
            state = .full
        } else if power.externalConnected {
            state = .plugged
        } else if snap.iokitAvailable {
            state = .unplugged
        } else {
            state = .unknown
        }

        // 未插电时这两个通道会停在 0.01 V 之类的残值，那不是读数，直接不给值
        let inputVoltage = power.externalConnected ? snap.voltage("VQ0u")?.value : nil
        let inputCurrent = power.externalConnected ? snap.current("IQ0u").map { abs($0.value) } : nil
        let inputWatts: Double? = {
            guard let v = inputVoltage, let i = inputCurrent, v > 0.5, i > 0.02 else { return nil }
            return v * i
        }()

        // 统一走 rail 解析：系统上报优先，其次已知 SMC 键，再次电池类通道。
        // 只认 IQ0B 会在 iPad 上读到一个恒为 0 的死通道。
        let batteryVoltage = snap.batteryVoltageRail()?.value
        let batteryCurrent = snap.batteryCurrentRail()?.value
        let batteryWatts: Double? = {
            guard let v = batteryVoltage, let i = batteryCurrent, abs(i) > 0.02 else { return nil }
            return v * i
        }()

        let sample = ChargeSample(
            id: sequence,
            time: now,
            inputVoltage: inputVoltage,
            inputCurrent: inputCurrent,
            inputWatts: inputWatts,
            batteryVoltage: batteryVoltage,
            batteryCurrent: batteryCurrent,
            batteryWatts: batteryWatts,
            batteryTemperature: snap.hottest(in: [.battery])?.value,
            chargerTemperature: snap.hottest(in: [.charger])?.value,
            socTemperature: snap.hottest(in: [.soc])?.value,
            level: snap.batteryLevel,
            state: state,
            adapterName: power.adapterName,
            adapterRatedWatts: power.adapterRatedWatts
        )

        // 只有确实在向电池充电时才累计，否则待机噪声会被积成「已充入 3 mAh」
        if power.charging, let current = batteryCurrent, abs(current) > 0.05, dt > 0 {
            if sessionStart == nil { sessionStart = now }
            sessionMilliampHours += abs(current) * 1000 * dt / 3600
            if let watts = batteryWatts, watts > 0 {
                sessionWattHours += watts * dt / 3600
                sessionPeakWatts = max(sessionPeakWatts, watts)
            }
        }

        samples.append(sample)
        if samples.count > Self.historyLimit {
            samples.removeFirst(samples.count - Self.historyLimit)
        }
        lastUpdate = now

        // 长期历史：只存每日聚合，不占内存，也不依赖任何导入文件。
        BatteryHistoryStore.shared.ingest(sample, dt: dt)
    }
}
