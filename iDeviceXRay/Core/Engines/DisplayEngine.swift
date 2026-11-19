import Foundation
import UIKit

/// 屏幕信息。分辨率/倍率/刷新率为实时读取，尺寸/PPI/面板类型来自机型库。
/// 面板供应商 iOS 完全不暴露，这里明确标为不可读取。
@MainActor
struct DisplayEngine {

    func collect(spec: DeviceSpec?) -> [ReportField] {
        let screen = UIScreen.main
        let bounds = screen.nativeBounds
        let width = Int(min(bounds.width, bounds.height).rounded())
        let height = Int(max(bounds.width, bounds.height).rounded())

        var fields: [ReportField] = []

        if width > 0, height > 0 {
            fields.append(ReportField(
                key: "display.resolution",
                title: "物理分辨率",
                value: "\(width) × \(height)",
                unit: "px",
                source: .live,
                confidence: .verified,
                note: "UIScreen.nativeBounds"
            ))
        }

        fields.append(ReportField(
            key: "display.scale",
            title: "渲染倍率",
            value: String(format: "%.1fx", Double(screen.scale)),
            source: .live,
            confidence: .verified
        ))

        if let spec, let inches = spec.screenInches {
            fields.append(ReportField(
                key: "display.size",
                title: "屏幕尺寸",
                value: String(format: "%.1f", inches),
                unit: "英寸",
                source: .catalog,
                confidence: .high
            ))
        }

        if let spec, let ppi = spec.ppi {
            fields.append(ReportField(
                key: "display.ppi",
                title: "像素密度",
                value: "\(ppi)",
                unit: "PPI",
                source: .catalog,
                confidence: .high
            ))
        }

        if let spec, let panel = spec.panelType {
            fields.append(ReportField(
                key: "display.panel",
                title: "面板类型",
                value: panel,
                source: .catalog,
                confidence: .inferred,
                note: "按机型推断，非面板自身上报，同型号不同批次可能不同"
            ))
        }

        if let spec, !spec.hasDetailedSpecs {
            fields.append(.unavailable(
                key: "display.size",
                title: "屏幕尺寸",
                reason: "机型库只收录了 \(spec.name) 的名称，该机型的尺寸与 PPI 尚未核对；上方分辨率为系统实测值"
            ))
        }

        fields.append(ReportField(
            key: "display.refresh",
            title: "帧率上限",
            value: "\(screen.maximumFramesPerSecond)",
            unit: "Hz",
            source: .live,
            confidence: .verified,
            note: "系统允许的最大帧率；实际刷新率随内容动态变化"
        ))

        fields.append(ReportField(
            key: "display.brightness",
            title: "当前亮度",
            value: Format.percent(Double(screen.brightness)),
            unit: "%",
            source: .live,
            confidence: .verified
        ))

        // 这两项是产品宣传里最容易吹过头的，明确写清楚不可读
        fields.append(.unavailable(
            key: "display.vendor",
            title: "面板供应商",
            reason: "iOS 不向第三方 App 暴露面板厂商，需导入诊断档案后从日志尝试推断"
        ))

        fields.append(.unavailable(
            key: "display.panelCode",
            title: "面板代号",
            reason: "仅当诊断日志中包含显示组件记录时才能推断"
        ))

        return fields
    }
}
