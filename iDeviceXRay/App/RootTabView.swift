import SwiftUI

struct RootTabView: View {
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
    }
}

#Preview {
    RootTabView()
        .preferredColorScheme(.dark)
}
