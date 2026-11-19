import Foundation

/// 深度数据融合：把诊断档案解析出的值，覆盖到对应 key 的字段上。
/// 覆盖后来源变为 `.sysdiagnose`，并统一使用已格式化的展示串。
enum DataFusion {

    static func merge(sections: [ReportSection], deep: DeepScanResult?) -> [ReportSection] {
        guard let deep, !deep.extraction.isEmpty else { return sections }

        return sections.map { section in
            let merged = section.fields.map { field -> ReportField in
                // 已经是实时读到的值就不覆盖：诊断档案是几十分钟前的快照，
                // 拿它盖掉传感器刚读的温度是把「实时」换成「过时」，属于倒退。
                guard field.confidence < .verified else { return field }
                guard let raw = deep.extraction[field.key], !raw.isEmpty else { return field }
                return ReportField(
                    key: field.key,
                    title: field.title,
                    value: raw,
                    unit: nil,
                    source: .sysdiagnose,
                    confidence: .high,
                    note: "解析自 \(deep.fileName)"
                )
            }
            return ReportSection(
                key: section.key,
                title: section.title,
                symbol: section.symbol,
                accentHex: section.accentHex,
                fields: merged
            )
        }
    }
}
