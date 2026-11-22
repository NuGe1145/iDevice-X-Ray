import Foundation

enum DeepScanError: LocalizedError {
    case fileTooLarge(Int64)
    case copyFailed
    case notDownloaded
    case unreadable
    case isDirectory
    case zipArchive
    case notArchive

    var errorDescription: String? {
        switch self {
        case .fileTooLarge(let size):
            return "文件 \(String(format: "%.0f", Double(size) / 1_048_576)) MB，超过 800 MB 上限"
        case .copyFailed:
            return "无法读取该文件。如果它来自 iCloud，先在「文件」里打开一次；也可以重新选择一次"
        case .notDownloaded:
            return "文件还在 iCloud 里，没有下载到本机。先在「文件」App 中打开它，等下载完成后再导入"
        case .unreadable:
            return "文件是空的或内容无法识别"
        case .isDirectory:
            return "选到的是文件夹。请进入文件夹，选中里面的 sysdiagnose_*.tar.gz"
        case .zipArchive:
            return "这是 zip 压缩包，App 读不了。请导入未经解压的 sysdiagnose_*.tar.gz；已经解压的话，只取 logs/powerlogs/CurrentPowerlog.PLSQL 导入即可"
        case .notArchive:
            return "这个文件既不是 sysdiagnose 压缩包（.tar.gz），也不是 Powerlog 数据库。如果它是 .txt 或其他日志，里面没有电池历史"
        }
    }
}

/// 靠文件头判断类型，不信扩展名 —— 从「文件」里转存常把 .tar.gz 改成
/// .gz、把 .PLSQL 改成 .sqlite，甚至干脆没有后缀。
enum ImportedFileKind: Equatable {
    case sqlite
    case gzip
    case zip
    case other
}

final class DeepScanService: @unchecked Sendable {

    static let shared = DeepScanService()

    private let maxFileSize: Int64 = 800 * 1024 * 1024

    func parse(
        url: URL,
        onProgress: @escaping (Double, String) -> Void
    ) async throws -> DeepScanResult {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<DeepScanResult, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try self.run(url: url, onProgress: onProgress)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func run(
        url: URL,
        onProgress: @escaping (Double, String) -> Void
    ) throws -> DeepScanResult {
        let started = Date()

        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        // 选择器放开成「任意文件」之后，用户有可能选到文件夹（或解压出来的目录）。
        // 这种情况 attributes 里的 size 是目录项大小，不能当文件读，先单独拦下来。
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            throw DeepScanError.isDirectory
        }

        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0

        guard size > 0 else {
            // iCloud 占位文件的 size 也是 0，先分清「没下载」和「真的空」
            if isNotDownloaded(url) { throw DeepScanError.notDownloaded }
            throw DeepScanError.unreadable
        }
        guard size <= maxFileSize else { throw DeepScanError.fileTooLarge(size) }

        let localURL = try copyToTemporary(url: url)
        defer { try? FileManager.default.removeItem(at: localURL) }

        // 单独传来的 Powerlog（电脑上解压后只取 CurrentPowerlog.PLSQL）不用走 tar，
        // 直接当 SQLite 读。比传 300MB 整包快得多，内容却是同一份。
        switch Self.kind(at: localURL) {
        case .sqlite:
            return runPowerlogOnly(
                displayName: url.lastPathComponent,
                localURL: localURL,
                size: size,
                started: started,
                onProgress: onProgress
            )
        case .zip:
            // zip 里的 sysdiagnose 还是要先解压，解压后内容一样，不值得再写一套 zip 解析
            throw DeepScanError.zipArchive
        case .gzip:
            break
        case .other:
            // 不是 gzip 的文件喂给 GzipStreamDecoder 只会得到一句「内容无法解析」，
            // 不如直接说清楚它到底是什么、该怎么拿对文件。
            throw DeepScanError.notArchive
        }

        // Powerlog 是几百 MB 的 SQLite，落在磁盘上给 SQLite 自己按页读，
        // 不能像日志文本那样整块进内存。
        let spillDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("powerlog-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: spillDirectory) }

        guard let handle = try? FileHandle(forReadingFrom: localURL) else {
            throw DeepScanError.copyFailed
        }
        defer { try? handle.close() }

        let scanner = TarScanner(keywords: DeepParser.interestingKeywords)
        // iOS 26/27 的包主库不再叫 CurrentPowerlog.PLSQL，而是
        // powerlog_2026-11-20_09-08_908E6B0B.PLSQL；只认旧名字的话整包导进来
        // 也拿不到循环次数。这里按后缀收，PaxHeader 里的同名元数据体积很小，
        // 用 1MB 门槛把它们排除。
        var spillIndex = 0
        // 真机包里同一份主库会出现两次：`logs/powerlogs/...` 和
        // `sysdiagnose_xxx/logs/powerlogs/...`。按文件名去重，否则 200MB 的库白写两遍。
        var spilledNames = Set<String>()
        scanner.spillPlan = { name, entrySize in
            guard Self.shouldSpillPowerlog(name: name, size: entrySize) else { return nil }
            guard spillIndex < 3 else { return nil }
            let base = (name as NSString).lastPathComponent.lowercased()
            guard spilledNames.insert(base).inserted else { return nil }

            spillIndex += 1
            let tag = name.lowercased().contains("powerlog") ? "main" : "aux"
            return spillDirectory.appendingPathComponent("\(tag)-\(spillIndex).PLSQL")
        }
        let decoder = try GzipStreamDecoder()

        var readBytes: Int64 = 0
        let total = max(size, 1)

        while true {
            let chunk = try handle.read(upToCount: 262_144) ?? Data()
            if chunk.isEmpty { break }

            readBytes += Int64(chunk.count)
            let plain = try decoder.write(chunk)
            if !plain.isEmpty {
                scanner.feed(plain)
            }

            let ratio = min(1.0, Double(readBytes) / Double(total))
            onProgress(min(0.85, ratio * 0.85), "解压并扫描归档 \(Int(ratio * 100))%")
        }

        try decoder.finish()
        scanner.finish()

        onProgress(0.9, "抽取电池与显示字段…")

        var outcome = DeepParser.parse(files: scanner.captured)

        var powerlogSummary: PowerlogSummary?
        if !scanner.spilledFiles.isEmpty {
            onProgress(0.94, "读取 Powerlog 电池历史…")
            // 主库（powerlog_*.PLSQL）排在前面；几个库都读一遍，取字段最全的那份
            let ordered = scanner.spilledFiles.sorted { lhs, rhs in
                let l = lhs.url.lastPathComponent.hasPrefix("main")
                let r = rhs.url.lastPathComponent.hasPrefix("main")
                return l && !r
            }
            for item in ordered {
                let read = PowerlogReader.read(url: item.url)
                if let summary = read.summary {
                    let better = powerlogSummary == nil
                        || summary.extraction.count > (powerlogSummary?.extraction.count ?? 0)
                    if better { powerlogSummary = summary }
                    for (key, value) in summary.extraction {
                        outcome.values[key] = value
                    }
                }
                outcome.notes.append(contentsOf: read.notes)
            }
        }

        onProgress(1.0, "解析完成")

        // 「未匹配到电池字段」每个文件一条，十几条会把真正重要的提示挤掉。
        // 这类归并成一句，其余保持原样。
        let unmatched = outcome.notes.filter { $0.contains("未匹配到") }
        var warnings = outcome.notes.filter { !$0.contains("未匹配到") }
        if !unmatched.isEmpty {
            warnings.append("\(unmatched.count) 个命中文件里没有可用字段，已跳过")
        }

        if scanner.matchedFiles.isEmpty {
            warnings.append("未在归档中找到电池或显示相关日志，请确认导入的是 sysdiagnose 压缩包")
        }
        if powerlogSummary == nil {
            warnings.append("档案里没有可用的 powerlog，循环次数与电池历史无法核对")
        } else if let summary = powerlogSummary, summary.cycleCount == nil {
            // 读到了库但缺循环次数：把命中的列写出来，截图就能定位是哪张表没接上
            let columns = summary.matchedColumns.prefix(4).joined(separator: ", ")
            warnings.append("Powerlog 读到 \(summary.rowCount) 行，但没有循环次数字段。命中列：\(columns)")
        }
        if outcome.values.isEmpty {
            warnings.append("未能提取到有效字段，可能是系统版本差异导致日志格式变化")
        }

        return DeepScanResult(
            fileName: url.lastPathComponent,
            fileSizeBytes: size,
            entriesScanned: scanner.entriesScanned,
            matchedFiles: Array(scanner.matchedFiles.prefix(20)),
            extraction: outcome.values,
            powerlog: powerlogSummary,
            warnings: Array(warnings.prefix(8)),
            durationSeconds: Date().timeIntervalSince(started)
        )
    }

    private func copyToTemporary(url: URL) throws -> URL {
        // 选择器用 asCopy 时，系统已经把文件复制进 App 的临时目录了。
        // sysdiagnose 常有 500MB+，再复制一遍等于白占一倍空间，直接用。
        let candidate = url.standardizedFileURL.resolvingSymlinksInPath().path
        let tmpRoot = FileManager.default.temporaryDirectory
            .standardizedFileURL.resolvingSymlinksInPath().path
        if candidate.hasPrefix(tmpRoot) {
            return url
        }

        let ext = url.pathExtension.isEmpty ? "bin" : url.pathExtension
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("import-\(UUID().uuidString).\(ext)")
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.copyItem(at: url, to: destination)
            return destination
        } catch {
            if isNotDownloaded(url) { throw DeepScanError.notDownloaded }
            throw DeepScanError.copyFailed
        }
    }

    private func isNotDownloaded(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]) else {
            return false
        }
        return values.ubiquitousItemDownloadingStatus == .notDownloaded
    }

    // MARK: - 裸数据库

    /// SQLite 文件头固定 16 字节。用它判断类型，比猜扩展名可靠 ——
    /// 用户从「文件」里选的 .PLSQL 有时会被系统改名成 .sqlite 或没有扩展名。
    static func kind(at url: URL) -> ImportedFileKind {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .other }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 16), !head.isEmpty else { return .other }

        let bytes = [UInt8](head)
        if bytes.starts(with: Array("SQLite format 3\u{0}".utf8)) { return .sqlite }
        if bytes.count >= 2, bytes[0] == 0x1F, bytes[1] == 0x8B { return .gzip }
        // 0x50 0x4B = "PK"，zip 与 docx/xlsx 共用这个头
        if bytes.count >= 2, bytes[0] == 0x50, bytes[1] == 0x4B { return .zip }
        return .other
    }

    static func isSQLite(at url: URL) -> Bool {
        kind(at: url) == .sqlite
    }

    /// 哪些条目要落盘交给 SQLite 读。
    ///
    /// iOS 26/27 的包主库是 `powerlog_2026-11-20_09-08_<hex>.PLSQL`，
    /// 只有老系统才叫 `CurrentPowerlog.PLSQL` —— 早前只认旧名字，整包导进来
    /// 却拿不到循环次数，就是这么来的。PaxHeader 里的同名条目只有几十字节，
    /// 1MB 门槛能顺手把它们排除。
    static func shouldSpillPowerlog(name: String, size: Int) -> Bool {
        guard size >= 1_048_576 else { return false }
        let lower = name.lowercased()
        if lower.hasSuffix(".plsql") { return true }
        // 兜底：万一归档里的名字仍被截断、或扩展名被改，路径本身也能定位主库。
        // log_*.BGSQL / *.EPSQL 同目录但不含 powerlog，不会误收。
        return lower.contains("/powerlogs/") && lower.contains("powerlog")
    }

    private func runPowerlogOnly(
        displayName: String,
        localURL: URL,
        size: Int64,
        started: Date,
        onProgress: @escaping (Double, String) -> Void
    ) -> DeepScanResult {
        onProgress(0.35, "读取 Powerlog 电池表…")
        let read = PowerlogReader.read(url: localURL)
        onProgress(0.95, "解析完成")

        var warnings = read.notes
        if read.summary == nil {
            warnings.append("这个数据库里没有找到可用的电池表，可能不是 powerlog")
        } else if let summary = read.summary, summary.cycleCount == nil {
            let columns = summary.matchedColumns.prefix(4).joined(separator: ", ")
            warnings.append("读到 \(summary.rowCount) 行，但没有循环次数字段。命中列：\(columns)")
        }

        return DeepScanResult(
            fileName: displayName,
            fileSizeBytes: size,
            entriesScanned: 0,
            matchedFiles: [displayName],
            extraction: read.summary?.extraction ?? [:],
            powerlog: read.summary,
            directDatabase: true,
            warnings: Array(warnings.prefix(8)),
            durationSeconds: Date().timeIntervalSince(started)
        )
    }
}
