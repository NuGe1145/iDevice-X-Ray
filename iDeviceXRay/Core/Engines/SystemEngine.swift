import Foundation
import LocalAuthentication
import UIKit

/// 系统状态。热状态与低电量模式是真实可用的；CPU 温度没有公开 API，
/// 因此这里用 thermalState 表达，而不是编一个温度数字。
@MainActor
struct SystemEngine {

    func collect() -> [ReportField] {
        var fields: [ReportField] = []

        fields.append(ReportField(
            key: "system.thermal",
            title: "热状态",
            value: thermalText(ProcessInfo.processInfo.thermalState),
            source: .live,
            confidence: .verified,
            note: "系统温度管理等级；iOS 不提供 CPU 温度数值"
        ))

        fields.append(.unavailable(
            key: "system.cpuTemperature",
            title: "CPU 温度",
            value: "",
            reason: "iOS 未开放温度传感器接口，任何显示具体温度数值的 App 都来自估算"
        ))

        fields.append(ReportField(
            key: "system.lowPowerMode",
            title: "低电量模式",
            value: ProcessInfo.processInfo.isLowPowerModeEnabled ? "已开启" : "关闭",
            source: .live,
            confidence: .verified
        ))

        fields.append(biometryField())

        let jailbreakPaths = checkedJailbreakPaths()
        fields.append(ReportField(
            key: "system.jailbreak",
            title: "越狱迹象",
            value: jailbreakPaths.isEmpty ? "未发现" : "发现可疑路径",
            source: .live,
            confidence: .inferred,
            note: jailbreakPaths.isEmpty
                ? "仅检查常见路径，App 沙箱无法访问系统分区，结论仅供参考"
                : "命中：\(jailbreakPaths.joined(separator: "、"))"
        ))

        return fields
    }

    private func thermalText(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "正常"
        case .fair: return "轻微升温"
        case .serious: return "较热，可能降频"
        case .critical: return "过热，系统已限制性能"
        @unknown default: return "未知"
        }
    }

    private func biometryField() -> ReportField {
        let context = LAContext()
        var error: NSError?
        let available = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)

        guard available else {
            return .unavailable(
                key: "system.biometry",
                title: "生物识别",
                reason: "未设置或不可用（\(error?.localizedDescription ?? "未知原因")）"
            )
        }

        let name: String
        switch context.biometryType {
        case .faceID: name = "Face ID"
        case .touchID: name = "Touch ID"
        case .opticID: name = "Optic ID"
        case .none: name = "未配置"
        @unknown default: name = "未知类型"
        }

        return ReportField(
            key: "system.biometry",
            title: "生物识别",
            value: name,
            source: .live,
            confidence: .verified
        )
    }

    private func checkedJailbreakPaths() -> [String] {
        let paths = [
            "/Applications/Cydia.app",
            "/Library/MobileSubstrate/MobileSubstrate.dylib",
            "/usr/sbin/sshd",
            "/etc/apt",
            "/private/var/lib/apt"
        ]
        return paths.filter { FileManager.default.fileExists(atPath: $0) }
    }
}
