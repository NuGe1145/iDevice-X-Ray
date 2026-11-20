import Foundation
import Observation

/// 从「文件」App 用本 App 打开文件时的中转站。
///
/// Info.plist 里早就声明了 sysdiagnose 的文档类型，系统会把本 App 列进
/// 「共享 / 用其他应用打开」；但之前没有 `onOpenURL` 的接收方，用户点了
/// 只会回到首页，看起来就是「导入没反应」。
@MainActor
@Observable
final class DeepScanCoordinator {

    static let shared = DeepScanCoordinator()

    private(set) var pendingURL: URL?

    private init() {}

    func accept(_ url: URL) {
        pendingURL = url
    }

    /// 取走并清空，避免同一文件被重复解析。
    func consume() -> URL? {
        defer { pendingURL = nil }
        return pendingURL
    }
}
