import Foundation
import Observation

/// 扫描调度：按固定顺序采集各引擎，合并深度数据，产出报告。
@Observable
final class ScanCoordinator {

    private(set) var isScanning = false
    private(set) var progress: Double = 0
    private(set) var stageText: String = ""

    @MainActor
    func run(mode: ScanMode, catalog: DeviceCatalog, deep: DeepScanResult? = nil) async -> ScanReport {
        isScanning = true
        progress = 0

        let steps: [(String, Double)] = [
            ("读取设备标识与芯片信息", 0.15),
            ("读取屏幕与显示参数", 0.35),
            ("读取电池、存储与系统状态", 0.6),
            ("核对机型库并标注来源", 0.8),
            ("生成体检报告", 0.95)
        ]

        for (title, value) in steps {
            stageText = title
            progress = value
            try? await Task.sleep(nanoseconds: 180_000_000)
        }

        let report = build(mode: mode, catalog: catalog, deep: deep)

        progress = 1
        stageText = "扫描完成"
        isScanning = false
        return report
    }

    @MainActor
    private func build(mode: ScanMode, catalog: DeviceCatalog, deep: DeepScanResult?) -> ScanReport {
        let identifier = DeviceIdentity.identifier
        let spec = catalog.spec(for: identifier)

        var sections: [ReportSection] = [
            ReportSection(
                key: "device",
                title: "设备概览",
                symbol: "iphone.gen3",
                accentHex: 0x22D3EE,
                fields: DeviceEngine().collect(catalog: catalog)
            ),
            ReportSection(
                key: "display",
                title: "屏幕与显示",
                symbol: "display",
                accentHex: 0xA855F7,
                fields: DisplayEngine().collect(spec: spec)
            ),
            ReportSection(
                key: "battery",
                title: "电池状态",
                symbol: "battery.75percent",
                accentHex: 0x34D399,
                fields: BatteryEngine().collect(spec: spec)
            ),
            ReportSection(
                key: "storage",
                title: "存储空间",
                symbol: "internaldrive",
                accentHex: 0xF59E0B,
                fields: StorageEngine().collect()
            ),
            ReportSection(
                key: "system",
                title: "系统状态",
                symbol: "cpu",
                accentHex: 0x60A5FA,
                fields: SystemEngine().collect()
            )
        ]

        sections = DataFusion.merge(sections: sections, deep: deep)

        return ScanReport(
            mode: mode,
            deviceName: spec?.name ?? "未知机型",
            identifier: identifier,
            osVersion: DeviceIdentity.osVersionString,
            sections: sections,
            deep: deep
        )
    }
}
