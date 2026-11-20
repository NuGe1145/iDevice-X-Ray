import SwiftUI

struct RootTabView: View {
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView {
            HomeView()
                .tabItem {
                    Label("首页", systemImage: "house.fill")
                }

            ReportListView()
                .tabItem {
                    Label("报告", systemImage: "doc.text.fill")
                }

            SettingsView()
                .tabItem {
                    Label("设置", systemImage: "gearshape.fill")
                }
        }
        .tint(Theme.primaryLight)
        .onChange(of: scenePhase) { _, phase in
            // 进后台就挂起采样：HID 在后台本来也读不到，留着只是耗电
            ChargeMonitor.shared.setForeground(phase == .active)
        }
    }
}

#Preview {
    RootTabView()
        .preferredColorScheme(.dark)
}
