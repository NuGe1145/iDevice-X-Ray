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

        guard let handle = try? FileHandle(forReadingFrom: localURL) else {
            throw DeepScanError.copyFailed
        }
        defer { try? handle.close() }

        let scanner = TarScanner(keywords: DeepParser.interestingKeywords)
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

        let outcome = DeepParser.parse(files: scanner.captured)

        onProgress(1.0, "解析完成")

        var warnings = outcome.notes
        if scanner.matchedFiles.isEmpty {
            warnings.append("未在归档中找到电池或显示相关日志，请确认导入的是 sysdiagnose 压缩包")
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
            warnings: Array(warnings.prefix(8)),
            durationSeconds: Date().timeIntervalSince(started)
        )
    }

    private func copyToTemporary(url: URL) throws -> URL {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("sysdiagnose-\(UUID().uuidString).tar.gz")
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.copyItem(at: url, to: destination)
            return destination
        } catch {
            throw DeepScanError.copyFailed
        }
    }
}
