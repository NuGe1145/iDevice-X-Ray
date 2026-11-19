import Foundation

/// 流式 tar 扫描器。
/// 只把「文件名命中关键词」的条目读进内存，其余条目按 512 字节块直接跳过，
/// 因此 300MB 的诊断包也不会撑爆内存。
final class TarScanner {

    private final class ActiveEntry {
        var remaining: Int
        let padding: Int
        let sink: (Data) -> Void

        init(remaining: Int, padding: Int, sink: @escaping (Data) -> Void) {
            self.remaining = remaining
            self.padding = padding
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

    private var buffer = [UInt8]()
    private var readIndex = 0
    private var current: ActiveEntry?
    private var skipRemaining = 0
    private var collectors: [Collector] = []

    private(set) var entriesScanned = 0
    private(set) var matchedFiles: [String] = []

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

    private func isInteresting(_ name: String) -> Bool {
        let lower = name.lowercased()
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
