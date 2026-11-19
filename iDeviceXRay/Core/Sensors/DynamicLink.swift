import Darwin
import Foundation

/// 私有框架的符号在编译期不链接，运行期用 dlsym 取。
///
/// 取不到就返回 nil，由上层把整块功能标成「本机不可用」并说明原因，
/// 而不是崩溃或显示 0。这也是本项目永远无法上架 App Store 的唯一原因。
enum DynamicLink {

    /// IOKit 在 iOS 上是私有框架，路径固定。
    static let iokitPath = "/System/Library/Frameworks/IOKit.framework/IOKit"

    static func open(_ path: String) -> UnsafeMutableRawPointer? {
        dlopen(path, RTLD_NOW)
    }

    static func symbol<T>(_ handle: UnsafeMutableRawPointer?, _ name: String, as type: T.Type) -> T? {
        guard let handle, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }
}
