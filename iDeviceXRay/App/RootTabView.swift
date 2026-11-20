import SwiftUI

@MainActor
struct RootTabView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var selection = 0
    @State private var intake = DeepScanCoordinator.shared

    var body: some View {
        TabView(selection: $selection) {
            HomeView()
                .tabItem {
                    Label("首页", systemImage: "house.fill")
                }
                .tag(0)

            ReportListView()
                .tabItem {
                    Label("报告", systemImage: "doc.text.fill")
                }
                .tag(1)

            SettingsView()
                .tabItem {
                    Label("设置", systemImage: "gearshape.fill")
                }
                .tag(2)
        }
        .tint(Theme.primaryLight)
        .onChange(of: scenePhase) { _, phase in
            // 进后台就挂起采样：HID 在后台本来也读不到，留着只是耗电
            ChargeMonitor.shared.setForeground(phase == .active)
        }
        .onChange(of: intake.pendingURL) { _, url in
            // 从「文件」App 打开时，先回到首页，由首页弹出深度检测
            guard url != nil else { return }
            selection = 0
        }
    }
}

#Preview {
    RootTabView()
        .preferredColorScheme(.dark)
}
