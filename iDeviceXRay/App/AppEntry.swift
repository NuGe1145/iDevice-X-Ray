import SwiftUI

@main
struct IDeviceXRayApp: App {
    var body: some Scene {
        WindowGroup {
            RootTabView()
                .preferredColorScheme(.dark)
                .onOpenURL { url in
                    // 从「文件」里长按 → 共享 → iDevice X-Ray，走这条
                    DeepScanCoordinator.shared.accept(url)
                }
        }
    }
}
