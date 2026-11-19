import SwiftUI

struct SettingsView: View {
    @State private var store = ReportStore.shared
    @State private var showClearConfirm = false

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    var body: some View {
        NavigationStack {
            PageContainer {
                aboutCard
                privacyCard
                dataCard
                openSourceCard
                disclaimerCard
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(Theme.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .confirmationDialog("确定清空所有本地报告？", isPresented: $showClearConfirm, titleVisibility: .visible) {
                Button("清空", role: .destructive) { store.clear() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("该操作不可撤销，报告仅保存在本机。")
            }
        }
    }

    private var aboutCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "关于", symbol: "info.circle", accent: Theme.cyan)

                infoRow("App 版本", appVersion)
                infoRow("机型库版本", DeviceCatalog.shared.version)
                infoRow("当前设备", DeviceIdentity.identifier)
                infoRow("系统版本", "iOS \(DeviceIdentity.osVersionString)")
                if let build = DeviceIdentity.buildNumber {
                    infoRow("系统 Build", build)
                }
            }
        }
    }

    private var privacyCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "隐私", symbol: "lock.shield", accent: Theme.success)

                privacyItem("无网络权限", "App 不发起任何网络请求，可完全离线使用", Theme.success)
                privacyItem("无账号体系", "不需要登录，不收集任何设备标识或个人数据", Theme.success)
                privacyItem("本地处理", "诊断档案解析、报告生成全部在本机完成", Theme.success)
                privacyItem("可随时清除", "报告与解析缓存都保存在沙盒内，卸载即清除", Theme.cyan)
            }
        }
    }

    private func privacyItem(_ title: String, _ detail: String, _ accent: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(accent)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var dataCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "数据", symbol: "internaldrive", accent: Theme.warning)

                infoRow("本地报告", "\(store.reports.count) 份")

                Button(role: .destructive) {
                    showClearConfirm = true
                } label: {
                    Label("清空所有报告", systemImage: "trash")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.danger)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Theme.danger.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(store.reports.isEmpty)
                .opacity(store.reports.isEmpty ? 0.4 : 1)
            }
        }
    }

    private var openSourceCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "开源", symbol: "chevron.left.forwardslash.chevron.right", accent: Theme.primaryLight)

                Text("本项目以 MIT 协议开源。机型规格库欢迎提交 PR 补充新机型；诊断档案的字段映射表需要真机样本持续校准。")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Link(destination: URL(string: "https://github.com")!) {
                    HStack {
                        Image(systemName: "link")
                        Text("在 GitHub 上查看")
                        Spacer()
                        Image(systemName: "arrow.up.right")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.primaryLight)
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private var disclaimerCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("免责声明")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
            Text("本 App 为设备信息工具，不提供维修建议。电池健康度、循环次数等指标依赖系统诊断档案，解析结果可能存在偏差，不能作为二手交易的唯一依据。")
                .font(.system(size: 10))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 4)
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.textPrimary)
        }
    }
}

#Preview {
    SettingsView()
        .preferredColorScheme(.dark)
}
