import Foundation
import UIKit

/// 电池。电量与充电状态可实时读取；循环次数、健康度、电压、温度
/// 没有任何公开 API，占位为「不可读取」，由深度扫描融合层填充。
@MainActor
struct BatteryEngine {

    func collect(spec: DeviceSpec?) -> [ReportField] {
        let device = UIDevice.current
        if !device.isBatteryMonitoringEnabled {
            device.isBatteryMonitoringEnabled = true
        }

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

        // 以下四项为深度指标占位
        fields.append(.unavailable(
            key: "battery.cycleCount",
            title: "循环次数",
            value: "",
            reason: "iOS 无公开 API，需导入 Sysdiagnose 后从电池日志解析"
        ))

        fields.append(.unavailable(
            key: "battery.health",
            title: "电池健康度",
            value: "",
            reason: "iOS 无公开 API，可在「设置 › 电池 › 电池健康」查看，或导入诊断档案"
        ))

        fields.append(.unavailable(
            key: "battery.voltage",
            title: "电池电压",
            value: "",
            reason: "需导入诊断档案解析 AppleSmartBattery 记录"
        ))

        fields.append(.unavailable(
            key: "battery.temperature",
            title: "电池温度",
            value: "",
            reason: "需导入诊断档案解析，公开 API 不可得"
        ))

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
