import Foundation

/// 对 sysctlbyname 的薄封装。全部为公开 C API，不涉及私有框架。
enum Sysctl {

    static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let value = String(cString: buffer)
        return value.isEmpty ? nil : value
    }

    static func int(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }

    static func int64(_ name: String) -> Int64? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }
}

enum DeviceIdentity {
    /// 机型标识符，如 "iPhone17,1"
    static var identifier: String {
        Sysctl.string("hw.machine") ?? "unknown"
    }

    /// 系统 Build 号，如 "23A344"
    static var buildNumber: String? {
        Sysctl.string("kern.osversion")
    }

    static var osVersionString: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        if version.patchVersion > 0 {
            return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        }
        return "\(version.majorVersion).\(version.minorVersion)"
    }

    static var cpuArchitecture: String {
        guard let type = Sysctl.int("hw.cputype") else { return "未知" }
        switch type {
        case 0x0100_000C: return "arm64"
        case 12: return "arm"
        case 0x0100_0007: return "x86_64"
        default: return "cputype \(type)"
        }
    }
}

enum Format {

    static func bytes(_ value: Int64) -> String {
        String(format: "%.1f GB", Double(value) / 1_000_000_000)
    }

    /// 只要数字，不带单位（用于需要自己拼 unit 的字段）
    static func gb(_ value: Int64) -> String {
        String(format: "%.1f", Double(value) / 1_000_000_000)
    }

    static func uptime(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        if days > 0 {
            return "\(days) 天 \(hours) 小时"
        }
        if hours > 0 {
            return "\(hours) 小时 \(minutes) 分"
        }
        return "\(minutes) 分钟"
    }

    static func dateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    static func percent(_ value: Double) -> String {
        String(format: "%.0f", value * 100)
    }
}
