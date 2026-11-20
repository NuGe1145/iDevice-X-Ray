import Foundation

/// App 自己 Documents 目录里的待导入文件。
///
/// Info.plist 开了 `UIFileSharingEnabled` 和 `LSSupportsOpeningDocumentsInPlace`，
/// 所以「文件」App 里能看到「我的 iPhone / iPad → iDevice X-Ray」这个文件夹。
/// 用户把 sysdiagnose 拖进去，App 一打开就能直接列出来解析 ——
/// 这条路径不经过系统文档选择器，也就不会遇到「文件看得见、点不动」的问题。
enum LocalImportFolder {

    static func directory() -> URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }

    /// 只挑出真正像样的文件：压缩包或 SQLite，且不小于 1MB。
    /// 系统会往 Documents 里放一些自己的东西（例如 Inbox），不能一律当候选。
    static func candidates(limit: Int = 5) -> [LocalImportCandidate] {
        guard let root = directory() else { return [] }

        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var found: [LocalImportCandidate] = []
        var visited = 0
        for case let url as URL in enumerator {
            visited += 1
            // 用户可能在 Documents 里堆了很多东西，扫够就停，别让进页面卡住
            if visited > 300 { break }

            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let size = values.fileSize,
                  size >= 1_048_576
            else { continue }

            let kind = DeepScanService.kind(at: url)
            guard kind == .gzip || kind == .sqlite else { continue }

            found.append(LocalImportCandidate(
                url: url,
                sizeBytes: Int64(size),
                modified: values.contentModificationDate ?? .distantPast
            ))
        }

        return Array(found.sorted { $0.modified > $1.modified }.prefix(limit))
    }
}

struct LocalImportCandidate: Identifiable, Sendable {
    var id: String { url.path }

    let url: URL
    let sizeBytes: Int64
    let modified: Date

    var name: String { url.lastPathComponent }

    var sizeText: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}
