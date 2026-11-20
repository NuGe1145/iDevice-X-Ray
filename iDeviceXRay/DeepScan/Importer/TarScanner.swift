import Foundation

/// 流式 tar 扫描器。
/// 只把「文件名命中关键词」且体积不大的条目读进内存，其余条目按 512 字节块直接跳过，
/// 因此 300MB 的诊断包也不会撑爆内存。
///
/// 例外是 `spillPlan`：命中它的条目（目前只有 Powerlog 的 SQLite）直接写到磁盘，
/// 既不进内存也不做文本解析——一个 200MB 的库读进 `Data` 就是一次必然的 OOM。
final class TarScanner {

    private final class ActiveEntry {
        var remaining: Int
        let padding: Int
        let sink: (Data) -> Void
        let onClose: (() -> Void)?

        init(
            remaining: Int,
            padding: Int,
            onClose: (() -> Void)? = nil,
            sink: @escaping (Data) -> Void
        ) {
            self.remaining = remaining
            self.padding = padding
            self.onClose = onClose
            self.sink = sink
        }
    }

    private final class Collector {
        let name: String
        private(set) var data = Data()

        init(name: String) {
            self.name = name
        }

        func append(_ chunk: Data) {
            data.append(chunk)
        }
    }

    let keywords: [String]
    let maxEntryBytes: Int

    /// 返回落盘路径表示该条目要写文件。返回 nil 表示按普通规则处理。
    var spillPlan: ((_ name: String, _ size: Int) -> URL?)?

    private var buffer = [UInt8]()
    private var readIndex = 0
    private var current: ActiveEntry?
    private var skipRemaining = 0
    private var collectors: [Collector] = []

    private var spillBudget = 720 * 1024 * 1024

    private(set) var entriesScanned = 0
    private(set) var matchedFiles: [String] = []
    private(set) var spilledFiles: [(name: String, url: URL, bytes: Int)] = []

    init(keywords: [String], maxEntryBytes: Int = 8 * 1024 * 1024) {
        self.keywords = keywords
        self.maxEntryBytes = maxEntryBytes
    }

    var captured: [(name: String, data: Data)] {
        collectors.map { ($0.name, $0.data) }
    }

    func feed(_ data: Data) {
        buffer.append(contentsOf: data)
        process()
    }

    func finish() {
        process()
        compact(force: true)
    }

    // MARK: - 状态机

    private func process() {
        var guardCounter = 0

        while guardCounter < 500_000 {
            guardCounter += 1

            // 1. 正在读取一个命中条目的内容
            if let entry = current {
                let available = buffer.count - readIndex
                if available == 0 { return }

                let take = min(entry.remaining, available)
                let chunk = Data(buffer[readIndex..<(readIndex + take)])
                entry.sink(chunk)
                readIndex += take
                entry.remaining -= take

                if entry.remaining == 0 {
                    entry.onClose?()
                    skipRemaining += entry.padding
                    current = nil
                } else {
                    compact()
                    return
                }

                compact()
                continue
            }

            // 2. 跳过不关心的内容
            if skipRemaining > 0 {
                let available = buffer.count - readIndex
                if available == 0 { return }
                let take = min(skipRemaining, available)
                readIndex += take
                skipRemaining -= take
                compact()
                continue
            }

            // 3. 读一个 512 字节头
            let available = buffer.count - readIndex
            guard available >= 512 else {
                compact()
                return
            }

            let header = Array(buffer[readIndex..<(readIndex + 512)])
            readIndex += 512

            if header.allSatisfy({ $0 == 0 }) {
                readIndex = buffer.count
                compact(force: true)
                return
            }

            entriesScanned += 1

            let name = Self.string(header, offset: 0, length: 100)
            let size = Self.octal(header, offset: 124, length: 12)
            let typeFlag = header[156]
            let padding = size > 0 ? (512 - (size % 512)) % 512 : 0

            if typeFlag == 0x35 { // '5' 目录
                continue
            }

            // 落盘优先：Powerlog 这类条目即使体积小也不该按文本处理
            if size > 0, size <= spillBudget, let url = spillPlan?(name, size) {
                if startSpill(name: name, size: size, padding: padding, url: url) {
                    spillBudget -= size
                    continue
                }
            }

            let matched = size > 0 && size <= maxEntryBytes && isInteresting(name)
            if matched {
                matchedFiles.append(name)
                let collector = Collector(name: name)
                collectors.append(collector)
                current = ActiveEntry(remaining: size, padding: padding) { chunk in
                    collector.append(chunk)
                }
            } else {
                skipRemaining += size + padding
            }
        }
    }

    private func startSpill(name: String, size: Int, padding: Int, url: URL) -> Bool {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: url.path, contents: nil)

        guard let handle = FileHandle(forWritingAtPath: url.path) else { return false }

        spilledFiles.append((name, url, size))
        matchedFiles.append(name)
        current = ActiveEntry(
            remaining: size,
            padding: padding,
            onClose: { try? handle.close() }
        ) { chunk in
            try? handle.write(contentsOf: chunk)
        }
        return true
    }

    private func isInteresting(_ name: String) -> Bool {
        let lower = name.lowercased()

        // PaxHeader 与 AppleDouble（同名 ._ 前缀）都是打包时产生的元数据，
        // 真实的 sysdiagnose 里每个文件都跟着一份，命中关键词却没有任何内容，
        // 只会把 matchedFiles 和解析用时撑大。
        if lower.contains("/paxheader/") { return false }
        let base = (lower as NSString).lastPathComponent
        if base.hasPrefix("._") { return false }

        return keywords.contains { lower.contains($0) }
    }

    private func compact(force: Bool = false) {
        guard force || readIndex > 1_048_576 else { return }
        if readIndex > 0 {
            buffer.removeFirst(readIndex)
            readIndex = 0
        }
    }

    // MARK: - tar 头解析

    private static func string(_ bytes: [UInt8], offset: Int, length: Int) -> String {
        let end = min(offset + length, bytes.count)
        guard offset < end else { return "" }
        var slice = Array(bytes[offset..<end])
        if let zero = slice.firstIndex(of: 0) {
            slice = Array(slice[..<zero])
        }
        return String(decoding: slice, as: UTF8.self)
    }

    private static func octal(_ bytes: [UInt8], offset: Int, length: Int) -> Int {
        let end = min(offset + length, bytes.count)
        guard offset < end else { return 0 }
        var value = 0
        var sawDigit = false
        for byte in bytes[offset..<end] {
            if byte == 0 || byte == 0x20 { continue }
            guard byte >= 48, byte <= 55 else { return sawDigit ? value : 0 }
            value = value * 8 + Int(byte - 48)
            sawDigit = true
        }
        return value
    }
}
