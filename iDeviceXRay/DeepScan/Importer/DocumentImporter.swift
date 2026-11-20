import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 用 UIKit 的文档选择器，替代 SwiftUI 的 `.fileImporter`。
///
/// iPad 上这条路径踩过两次坑：过滤器里混进动态 UTType 会让所有文件变灰；
/// 换掉过滤之后，浮窗能正常显示、文件也是亮的，但点文件毫无反应 —— 因为
/// SwiftUI 的 `.fileImporter` 挂在「已经从 sheet 弹出来的页面」上，多一层
/// 呈现，触摸事件被外层吞掉了。
///
/// 直接由当前最顶层的 UIViewController present，绕开 SwiftUI 的呈现层级。
/// `asCopy: true` 会让系统先把文件复制到 App 沙盒再回调，顺带解决 iCloud
/// 占位文件读不到、security-scoped 授权失败这两类问题。
@MainActor
final class DocumentImporter: NSObject, UIDocumentPickerDelegate {

    static let shared = DocumentImporter()

    private var completion: (@MainActor (Result<URL, Error>) -> Void)?

    private override init() {
        super.init()
    }

    func present(completion: @escaping @MainActor (Result<URL, Error>) -> Void) {
        // 连点两下会叠两层选择器，第二次直接忽略
        guard self.completion == nil else { return }
        self.completion = completion

        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [.item],
            asCopy: true
        )
        picker.delegate = self
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true

        guard let host = Self.topViewController() else {
            self.completion = nil
            completion(.failure(ImportPickerError.noHost))
            return
        }

        host.present(picker, animated: true)
    }

    // MARK: - UIDocumentPickerDelegate

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        let callback = completion
        completion = nil
        guard let url = urls.first else { return }
        callback?(.success(url))
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        // 取消不弹错，静默回到页面
        completion = nil
    }

    // MARK: - 找到最顶层的 VC

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        guard let window = scene?.windows.first(where: { $0.isKeyWindow }) ?? scene?.windows.first,
              var top = window.rootViewController
        else { return nil }

        // 顺着 presented 链一路向下，跳过正在消失的那一层
        while let presented = top.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        // sheet 里的内容是 NavigationStack 时，present 在它上面才会盖住当前页
        if let nav = top as? UINavigationController, let visible = nav.visibleViewController {
            top = visible
        }
        if let tab = top as? UITabBarController, let selected = tab.selectedViewController {
            top = selected
        }
        return top
    }
}

enum ImportPickerError: LocalizedError {
    case noHost

    var errorDescription: String? {
        switch self {
        case .noHost:
            return "界面还没准备好，返回上一页再进一次试试"
        }
    }
}
