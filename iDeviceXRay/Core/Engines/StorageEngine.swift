import Foundation

/// 存储。iOS 只暴露数据分区的总量与可用量，无法拆分「照片/App/系统」占用。
struct StorageEngine {

    func collect() -> [ReportField] {
        let path = NSHomeDirectory()
        let attributes = try? FileManager.default.attributesOfFileSystem(forPath: path)
        let total = (attributes?[.systemSize] as? NSNumber)?.int64Value ?? 0
        let free = (attributes?[.systemFreeSize] as? NSNumber)?.int64Value ?? 0

        guard total > 0 else {
            return [
                .unavailable(key: "storage.total", title: "总容量", reason: "无法读取文件系统属性"),
                .unavailable(key: "storage.used", title: "已用空间", reason: "无法读取文件系统属性"),
                .unavailable(key: "storage.free", title: "可用空间", reason: "无法读取文件系统属性")
            ]
        }

        let used = max(0, total - free)
        let ratio = Double(used) / Double(total)

        return [
            ReportField(
                key: "storage.total",
                title: "总容量",
                value: Format.bytes(total),
                source: .live,
                confidence: .verified,
                note: "系统数据分区容量，与标称容量存在差异（格式化与系统占用）"
            ),
            ReportField(
                key: "storage.used",
                title: "已用空间",
                value: Format.bytes(used),
                source: .live,
                confidence: .verified
            ),
            ReportField(
                key: "storage.free",
                title: "可用空间",
                value: Format.bytes(free),
                source: .live,
                confidence: .verified,
                note: "不含系统可自动清理的缓存空间"
            ),
            ReportField(
                key: "storage.usage",
                title: "使用率",
                value: Format.percent(ratio),
                unit: "%",
                source: .live,
                confidence: .verified
            )
        ]
    }
}
