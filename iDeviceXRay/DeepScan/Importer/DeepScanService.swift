import Foundation

enum DeepScanError: LocalizedError {
    case fileTooLarge(Int64)
    case copyFailed
    case unreadable

    var errorDescription: String? {
        switch self {
        case .fileTooLarge(let size):
            return "文件 \(String(format: "%.0f", Double(size) / 1_048_576)) MB，超过 800 MB 上限"
        case .copyFailed:
            return "无法读取该文件，请重新从「文件」App 选择"
        case .unreadable:
            return "文件内容无法解析"
        }
    }
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

        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0

        guard size > 0 else { throw DeepScanError.unreadable }
        guard size <= maxFileSize else { throw DeepScanError.fileTooLarge(size) }

        let localURL = try copyToTemporary(url: url)
        defer { try? FileManager.default.removeItem(at: localURL) }

        // 单独传来的 Powerlog（电脑上解压后只取 CurrentPowerlog.PLSQL）不用走 tar，
        // 直接当 SQLite 读。比传 300MB 整包快得多，内容却是同一份。
        if Self.isSQLite(at: localURL) {
            return runPowerlogOnly(
                displayName: url.lastPathComponent,
                localURL: localURL,
                size: size,
                started: started,
                onProgress: onProgress
            )
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
        scanner.spillPlan = { name, _ in
            let lower = name.lowercased()
            guard lower.hasSuffix("currentpowerlog.plsql") else { return nil }
            return spillDirectory.appendingPathComponent("CurrentPowerlog.PLSQL")
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
            for item in scanner.spilledFiles {
                let read = PowerlogReader.read(url: item.url)
                if let summary = read.summary {
                    powerlogSummary = summary
                    for (key, value) in summary.extraction {
                        outcome.values[key] = value
                    }
                }
                outcome.notes.append(contentsOf: read.notes)
            }
        }

        onProgress(1.0, "解析完成")

        var warnings = outcome.notes
        if scanner.matchedFiles.isEmpty {
            warnings.append("未在归档中找到电池或显示相关日志，请确认导入的是 sysdiagnose 压缩包")
        }
        if powerlogSummary == nil {
            warnings.append("档案里没有可用的 powerlog，循环次数与电池历史无法核对")
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
        let ext = url.pathExtension.isEmpty ? "bin" : url.pathExtension
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("import-\(UUID().uuidString).\(ext)")
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.copyItem(at: url, to: destination)
            return destination
        } catch {
            throw DeepScanError.copyFailed
        }
    }

    // MARK: - 裸数据库

    /// SQLite 文件头固定 16 字节。用它判断类型，比猜扩展名可靠 ——
    /// 用户从「文件」里选的 .PLSQL 有时会被系统改名成 .sqlite 或没有扩展名。
    static func isSQLite(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 16), head.count == 16 else { return false }
        return head.starts(with: Data("SQLite format 3\u{0}".utf8))
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
            warnings.append("这个数据库里没有找到 PLBatteryAgent* 电池表，可能不是 powerlog")
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
