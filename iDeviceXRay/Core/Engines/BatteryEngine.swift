import Foundation
import UIKit

/// 电池。电量与充电状态来自公开 API；电压、温度来自私有 SMC 通道；
/// 容量与健康度由本机充电片段积分估算；循环次数只能靠导入诊断档案。
///
/// 这里的取舍：宁可显示「—」并说明原因，也不把机型规格当成实测值。
/// 每一项都带来源与可信度，用户能判断该不该信。
@MainActor
struct BatteryEngine {

    func collect(spec: DeviceSpec?) -> [ReportField] {
        let device = UIDevice.current
        if !device.isBatteryMonitoringEnabled {
            device.isBatteryMonitoringEnabled = true
        }

        let history = BatteryHistoryStore.shared
        let snapshot = ChargeMonitor.shared.snapshot
        var fields: [ReportField] = []

        let level = device.batteryLevel
        if level >= 0 {
            fields.append(ReportField(
                key: "battery.level",
                title: "当前电量",
                value: Format.percent(Double(level)),
                unit: "%",
                source: .live,
                confidence: .verified
            ))
        } else {
            fields.append(.unavailable(
                key: "battery.level",
                title: "当前电量",
                reason: "系统未上报电量（模拟器通常为 -1）"
            ))
        }

        fields.append(ReportField(
            key: "battery.state",
            title: "充电状态",
            value: chargingStateText(device.batteryState),
            source: .live,
            confidence: .verified
        ))

        // MARK: 实时电压与温度（私有 SMC 通道，无需任何导入）

        if let reading = snapshot.voltage("VP0u") ?? snapshot.voltage("VQ0l"),
           reading.value.isFinite, (2.5...5.5).contains(reading.value) {
            fields.append(ReportField(
                key: "battery.voltage",
                title: "电池电压",
                value: String(format: "%.2f", reading.value),
                unit: "V",
                source: .privateAPI,
                confidence: .high,
                note: "SMC 通道 \(reading.key)，随采样实时更新"
            ))
        } else {
            fields.append(.unavailable(
                key: "battery.voltage",
                title: "电池电压",
                reason: "采样循环尚未运行；打开任意实时页面后即可读取，或导入诊断档案"
            ))
        }

        if let reading = snapshot.hottest(in: [.battery]),
           reading.value.isFinite, (-40...150).contains(reading.value) {
            fields.append(ReportField(
                key: "battery.temperature",
                title: "电池温度",
                value: String(format: "%.1f", reading.value),
                unit: "°C",
                source: .privateAPI,
                confidence: .high,
                note: "来自 \(reading.key) 传感器，随采样实时更新"
            ))
        } else {
            fields.append(.unavailable(
                key: "battery.temperature",
                title: "电池温度",
                reason: "未发现可用的电池温度通道；打开充电页可看到各测点的实时值"
            ))
        }

        // MARK: 容量与健康度（本机积分估算）

        if let estimate = history.capacityEstimate {
            fields.append(ReportField(
                key: "battery.maxCapacity",
                title: "实测容量（估算）",
                value: "\(Int(estimate.milliampereHours.rounded()))",
                unit: "mAh",
                source: .localHistory,
                confidence: .inferred,
                note: "由 \(estimate.sampleCount) 次充电片段积分取中位数，误差约 ±5%"
            ))
        } else {
            fields.append(.unavailable(
                key: "battery.maxCapacity",
                title: "实测容量（估算）",
                value: "",
                reason: "需要一次连续 20% 以上的充电；也可导入诊断档案直接读原始记录"
            ))
        }

        if let percent = history.healthPercent(designMah: spec?.batteryDesignMah) {
            fields.append(ReportField(
                key: "battery.health",
                title: "电池健康度",
                value: String(format: "%.0f", percent),
                unit: "%",
                source: .localHistory,
                confidence: .inferred,
                note: "按本机充电积分估算，非系统读数；系统值在「设置 › 电池 › 电池健康」"
            ))
        } else {
            fields.append(.unavailable(
                key: "battery.health",
                title: "电池健康度",
                value: "",
                reason: "系统未开放此接口；本机估算需要一次完整些的充电，或导入诊断档案"
            ))
        }

        if let capacity = spec?.batteryDesignMah {
            fields.append(ReportField(
                key: "battery.designCapacity",
                title: "设计容量",
                value: "\(capacity)",
                unit: "mAh",
                source: .catalog,
                confidence: .high,
                note: "按机型规格，非本机实测"
            ))
        } else {
            fields.append(.unavailable(
                key: "battery.designCapacity",
                title: "设计容量",
                value: "",
                reason: "机型库未收录该机型的电池设计容量"
            ))
        }

        fields.append(.unavailable(
            key: "battery.cycleCount",
            title: "循环次数",
            value: "",
            reason: "iOS 不向第三方 App 暴露循环次数（设置里也不显示）；只有 Powerlog 有原始计数"
        ))

        if let first = history.firstRecordDate {
            fields.append(ReportField(
                key: "battery.historySpan",
                title: "本机记录",
                value: "\(max(1, history.recordedDayCount))",
                unit: "天",
                source: .localHistory,
                confidence: .high,
                note: "从 \(first.formatted(date: .numeric, time: .omitted)) 开始，只覆盖安装之后的时间"
            ))
        } else {
            fields.append(.unavailable(
                key: "battery.historySpan",
                title: "本机记录",
                value: "",
                reason: "还没有历史数据；打开充电页采样一次即开始记录"
            ))
        }

        return fields
    }

    private func chargingStateText(_ state: UIDevice.BatteryState) -> String {
        switch state {
        case .charging: return "充电中"
        case .full: return "已充满"
        case .unplugged: return "使用电池"
        case .unknown: return "未知"
        @unknown default: return "未知"
        }
    }
}
