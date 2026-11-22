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

    /// PAX / GNU 长名条目里存着下一个真实文件的完整路径。
    /// sysdiagnose 的深层目录很容易超过 tar 头的 100 字节限制，名字会被截断；
    /// 不把这段接上，`powerlog_*.PLSQL` 就会变成一个没有扩展名的残名而被漏掉。
    private var pendingName: String?
    private var metaBuffer = Data()

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

            let size = Self.octal(header, offset: 124, length: 12)
            let typeFlag = header[156]
            let padding = size > 0 ? (512 - (size % 512)) % 512 : 0

            // 'x' / 'g' 是 PAX 扩展头，'L' / 'K' 是 GNU 长名，都只是下一个条目的元数据
            if typeFlag == 0x78 || typeFlag == 0x67 || typeFlag == 0x4C || typeFlag == 0x4B {
                readMetadata(size: size, padding: padding, typeFlag: typeFlag)
                continue
            }

            // ustar 把超过 100 字节的路径拆成 prefix + name 两段
            var name = Self.string(header, offset: 0, length: 100)
            if Self.string(header, offset: 257, length: 5) == "ustar" {
                let prefix = Self.string(header, offset: 345, length: 155)
                if Self.isPrintablePath(prefix) {
                    name = prefix + "/" + name
                }
            }

            // 名字被截断时，真正的完整路径在前一个扩展头里
            if let pending = pendingName {
                name = pending
                pendingName = nil
            }

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

    /// 扩展头体积都很小（通常几十字节）。超过 256KB 的直接跳过，
    /// 免得畸形包把它当成内容条目读进内存。
    private func readMetadata(size: Int, padding: Int, typeFlag: UInt8) {
        guard size > 0, size <= 262_144 else {
            skipRemaining += size + padding
            return
        }

        let isPAX = typeFlag == 0x78 || typeFlag == 0x67
        let isGNUName = typeFlag == 0x4C

        metaBuffer = Data()
        metaBuffer.reserveCapacity(size)

        current = ActiveEntry(remaining: size, padding: padding, onClose: { [weak self] in
            guard let self else { return }
            defer { self.metaBuffer = Data() }

            if isGNUName {
                var bytes = [UInt8](self.metaBuffer)
                if let zero = bytes.firstIndex(of: 0) { bytes = Array(bytes[..<zero]) }
                let value = String(decoding: bytes, as: UTF8.self)
                if !value.isEmpty { self.pendingName = value }
            } else if isPAX {
                if let path = Self.paxPath(in: self.metaBuffer) { self.pendingName = path }
            }
        }) { [weak self] chunk in
            self?.metaBuffer.append(chunk)
        }
    }

    /// PAX 记录格式：`<总长> <key>=<value>\n`，长度含自身。
    private static func paxPath(in data: Data) -> String? {
        let bytes = [UInt8](data)
        var index = 0

        while index < bytes.count {
            var cursor = index
            var length = 0
            var digits = 0
            while cursor < bytes.count, bytes[cursor] >= 48, bytes[cursor] <= 57 {
                length = length * 10 + Int(bytes[cursor] - 48)
                cursor += 1
                digits += 1
            }

            guard digits > 0, cursor < bytes.count, bytes[cursor] == 0x20,
                  length > 0, index + length <= bytes.count else { return nil }

            var record = Array(bytes[(cursor + 1)..<(index + length)])
            while let last = record.last, last == 0x0A || last == 0 { record.removeLast() }

            if let equals = record.firstIndex(of: 0x3D) {
                let key = String(decoding: record[..<equals], as: UTF8.self)
                let value = String(decoding: record[(equals + 1)...], as: UTF8.self)
                if key == "path", !value.isEmpty { return value }
            }
            index += length
        }
        return nil
    }

    /// GNU tar 会把 atime 之类的纯数字塞在 prefix 位置，只有像路径才拼接。
    private static func isPrintablePath(_ text: String) -> Bool {
        guard !text.isEmpty, text.utf8.count <= 155 else { return false }
        guard text.utf8.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return false }
        return text.contains { $0.isLetter || $0 == "_" }
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
