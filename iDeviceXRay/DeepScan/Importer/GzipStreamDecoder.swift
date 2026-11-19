import Foundation
import Compression

enum GzipError: LocalizedError {
    case cannotInit
    case invalidHeader
    case decodeFailed

    var errorDescription: String? {
        switch self {
        case .cannotInit: return "无法初始化解压器"
        case .invalidHeader: return "不是有效的 gzip 文件"
        case .decodeFailed: return "解压失败，文件可能已损坏"
        }
    }
}

/// gzip 头部解析。sysdiagnose 由系统打包，可能带 FNAME/FEXTRA 等可选字段。
enum GzipHeader {

    static func length(in data: Data) -> Int? {
        guard data.count >= 10 else { return nil }
        let bytes = [UInt8](data.prefix(10))
        guard bytes[0] == 0x1F, bytes[1] == 0x8B else { return nil }

        let flags = bytes[3]
        var offset = 10
        let total = data.count
        let all = [UInt8](data)

        if flags & 0x04 != 0 { // FEXTRA
            guard offset + 2 <= total else { return nil }
            let xlen = Int(all[offset]) | (Int(all[offset + 1]) << 8)
            offset += 2 + xlen
        }

        if flags & 0x08 != 0 { // FNAME
            while offset < total, all[offset] != 0 { offset += 1 }
            offset += 1
        }

        if flags & 0x10 != 0 { // FCOMMENT
            while offset < total, all[offset] != 0 { offset += 1 }
            offset += 1
        }

        if flags & 0x02 != 0 { // FHCRC
            offset += 2
        }

        guard offset <= total else { return nil }
        return offset
    }
}

/// 流式 gunzip。只解压、不落盘，内存占用与文件大小无关。
final class GzipStreamDecoder {

    private var stream: compression_stream
    private var isInitialized = false
    private var headerConsumed = false
    private var pending = Data()
    private var finished = false

    init() throws {
        stream = compression_stream(dst_ptr: nil, dst_size: 0, src_ptr: nil, src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw GzipError.cannotInit
        }
        isInitialized = true
    }

    deinit {
        if isInitialized {
            compression_stream_destroy(&stream)
        }
    }

    func write(_ data: Data) throws -> Data {
        if finished { return Data() }

        var payload = data

        if !headerConsumed {
            pending.append(data)
            guard pending.count >= 10 else { return Data() }
            guard let headerLength = GzipHeader.length(in: pending) else {
                throw GzipError.invalidHeader
            }
            payload = pending.subdata(in: headerLength..<pending.count)
            pending.removeAll(keepingCapacity: true)
            headerConsumed = true
        }

        guard !payload.isEmpty else { return Data() }
        return try pump(payload)
    }

    /// 文件读完后调用。输出已在每次 pump 中刷完，这里只做状态收尾。
    func finish() throws -> Data {
        guard headerConsumed else { throw GzipError.invalidHeader }
        return Data()
    }

    private func pump(_ input: Data) throws -> Data {
        var output = Data()
        let capacity = 64 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { buffer.deallocate() }

        try input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            stream.src_ptr = base
            stream.src_size = input.count

            var iterations = 0
            while iterations < 20_000 {
                iterations += 1

                stream.dst_ptr = buffer
                stream.dst_size = capacity

                let status = compression_stream_process(&stream, 0)
                let produced = capacity - stream.dst_size
                if produced > 0 {
                    output.append(buffer, count: produced)
                }

                if status == COMPRESSION_STATUS_END {
                    finished = true
                    return
                }
                if status == COMPRESSION_STATUS_ERROR {
                    throw GzipError.decodeFailed
                }
                if stream.src_size == 0 && produced == 0 {
                    return
                }
            }
        }

        return output
    }
}
