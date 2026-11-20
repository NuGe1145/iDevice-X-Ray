import SwiftUI

@MainActor
struct SectionDetailView: View {
    let section: ReportSection
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var monitor = ChargeMonitor.shared
    /// 每个页面实例一个 token：同一分区可能同时被首页与报告页打开，
    /// 用 Set 登记，谁退出都不会把别人的采样停掉。
    @State private var token = UUID().uuidString

    private var accent: Color { Color(hex: section.accentHex) }

    /// 充电、温度、电池这三页的时间性数据都来自监控循环，其余分区仍是扫描快照。
    private var isLive: Bool {
        ["power", "thermal", "battery"].contains(section.key)
    }

    private var currentSection: ReportSection {
        guard isLive, monitor.sampleCount > 0 else { return section }
        return PowerSensorEngine().liveSection(for: section, from: monitor.snapshot)
    }

    var body: some View {
        NavigationStack {
            PageContainer {
                if section.key == "power" {
                    ChargeLiveCard(monitor: monitor)
                } else {
                    if isLive {
                        LiveStatusBar(monitor: monitor)
                    }
                    summaryCard
                }

                GlassCard {
                    VStack(spacing: 0) {
                        ForEach(Array(currentSection.fields.enumerated()), id: \.element.id) { index, field in
                            FieldRow(field: field)
                            if index < currentSection.fields.count - 1 {
                                Rectangle()
                                    .fill(Color.white.opacity(0.06))
                                    .frame(height: 1)
                            }
                        }
                    }
                }

                if section.key == "battery" {
                    LocalHistoryCard()
                }

                hintCard
            }
            .navigationTitle(section.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                        .foregroundStyle(Theme.primaryLight)
                }
            }
            .toolbarBackground(Theme.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
        .onAppear {
            guard isLive else { return }
            UIDevice.current.isBatteryMonitoringEnabled = true
            monitor.begin(token)
        }
        .onDisappear {
            guard isLive else { return }
            monitor.end(token)
        }
        .onChange(of: scenePhase) { _, phase in
            monitor.setForeground(phase == .active)
        }
    }

    private var summaryCard: some View {
        GlassCard {
            HStack(spacing: 14) {
                Image(systemName: section.symbol)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 48, height: 48)
                    .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text("\(currentSection.readableCount) / \(currentSection.fields.count) 项可读取")
                        .font(.system(.headline, design: .rounded))
                        .foregroundStyle(Theme.textPrimary)
                    Text("点击任意一行查看数据来源")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                }

                Spacer(minLength: 0)
            }
        }
    }

    private var hintCard: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: isLive ? "waveform.path.ecg" : "hand.tap")
                .font(.system(size: 11))
            Text(hintText)
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Theme.textTertiary)
        .padding(.horizontal, 4)
    }

    private var hintText: String {
        if !isLive {
            return "点击任意一行，可查看该项数据的来源与说明。标为「不可读取」的项目，本机确实拿不到，我们不会用估算值填充。"
        }
        return "本页数值随采样实时更新，每 \(Int(monitor.refreshInterval)) 秒一次；间隔可在设置里调整。没有传感器的通道显示「—」并给出原因，不做估算。"
    }
}

#Preview {
    SectionDetailView(
        section: ReportSection(
            key: "demo",
            title: "设备概览",
            symbol: "iphone.gen3",
            accentHex: 0x22D3EE,
            fields: [
                ReportField(key: "a", title: "设备型号", value: "iPhone 16 Pro", source: .catalog, confidence: .high),
                ReportField(key: "b", title: "机型标识", value: "iPhone17,1", source: .live, confidence: .verified),
                ReportField.unavailable(key: "c", title: "面板供应商", reason: "iOS 不向第三方 App 暴露")
            ]
        )
    )
    .preferredColorScheme(.dark)
}
