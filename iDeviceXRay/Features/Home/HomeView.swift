import SwiftUI
import UIKit

@MainActor
struct HomeView: View {
    @State private var store = ReportStore.shared
    @State private var scanner = ScanCoordinator()

    @State private var latest: ScanReport?
    @State private var sheet: HomeSheet?
    @State private var didAutoScan = false
    @State private var energy = ChargeMonitor.shared
    @State private var isPlugged = false
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase

    private let chargeToken = "home"

    var body: some View {
        NavigationStack {
            PageContainer {
                header
                statusCard
                if isPlugged, energy.latest != nil {
                    ChargeLiveStrip(monitor: energy) { openPower() }
                }
                modeRow
                quickAccess
                legendCard
                footer
            }
            .toolbar(.hidden, for: .navigationBar)
            .task {
                UIDevice.current.isBatteryMonitoringEnabled = true
                syncChargingMonitor()
                guard !didAutoScan else { return }
                didAutoScan = true
                await scan(deep: nil, save: false)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryStateDidChangeNotification)) { _ in
                syncChargingMonitor()
            }
            .onChange(of: scenePhase) { _, phase in
                energy.setForeground(phase == .active)
            }
            .onDisappear {
                energy.end(chargeToken)
            }
            .sheet(item: $sheet) { item in
                sheetContent(item)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    /// 插上电才起监控循环，拔掉就停：首页不需要每秒读一次 HID，
    /// 但插拔事件由系统通知即时触发，不会漏掉。
    private func syncChargingMonitor() {
        let state = UIDevice.current.batteryState
        isPlugged = state == .charging || state == .full
        if state == .charging || state == .full || state == .unknown {
            energy.begin(chargeToken)
        } else {
            energy.end(chargeToken)
        }
    }

    private func openPower() {
        guard let latest, let section = latest.section("power") else { return }
        sheet = .section(section)
    }


    // MARK: - 头部

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Theme.accentGradient)
                    .frame(width: 46, height: 46)
                    .shadow(color: Theme.primary.opacity(0.5), radius: 12, y: 4)
                Image(systemName: "viewfinder")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("iDevice X-Ray")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                Text("探索设备深处，发现更多可能")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
            }

            Spacer(minLength: 0)

            HStack(spacing: 4) {
                Image(systemName: "wifi.slash")
                    .font(.system(size: 9, weight: .bold))
                Text("离线")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(Theme.success)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Theme.success.opacity(0.12), in: Capsule())
        }
        .padding(.top, 4)
    }

    // MARK: - 状态卡

    private var statusCard: some View {
        GlassCard(padding: 20) {
            VStack(spacing: 16) {
                HStack(spacing: 18) {
                    ZStack {
                        GlowRing(
                            progress: scanner.isScanning ? max(scanner.progress, 0.06) : 1,
                            size: 92,
                            lineWidth: 7
                        )
                        Image(systemName: "apple.logo")
                            .font(.system(size: 30))
                            .foregroundStyle(Theme.textPrimary)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text(scanner.isScanning ? "正在扫描设备" : "设备扫描完成")
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                            .foregroundStyle(Theme.textPrimary)

                        Text(statusSubtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)

                        if scanner.isScanning {
                            Text(scanner.stageText)
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.cyan)
                        } else if let latest {
                            Text("\(latest.deviceName) · iOS \(latest.osVersion)")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.textTertiary)
                        }
                    }

                    Spacer(minLength: 0)
                }

                if let latest, !scanner.isScanning {
                    HStack(spacing: 8) {
                        miniStat(value: "\(latest.readableCount)", title: "可读项", accent: Theme.success)
                        miniStat(value: "\(latest.verifiedCount)", title: "已验证", accent: Theme.cyan)
                        miniStat(value: "\(latest.completenessScore)%", title: "完整度", accent: Theme.primaryLight)
                    }
                }
            }
        }
    }

    private var statusSubtitle: String {
        if let latest {
            return "共 \(latest.totalCount) 项信息，其中 \(latest.readableCount) 项成功读取"
        }
        return "正在读取设备基础信息"
    }

    private func miniStat(value: String, title: String, accent: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(accent)
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - 双模式

    private var modeRow: some View {
        HStack(spacing: 12) {
            Button {
                Task { await scan(deep: nil, save: true) }
            } label: {
                Label("标准检测", systemImage: "bolt.fill")
            }
            .buttonStyle(GradientButtonStyle())
            .disabled(scanner.isScanning)

            Button {
                sheet = .deepScan
            } label: {
                Label("深度检测", systemImage: "doc.text.magnifyingglass")
            }
            .buttonStyle(GhostButtonStyle())
        }
    }

    // MARK: - 快速入口

    private var quickAccess: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("快速入口")
                    .font(.system(.headline, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                if let latest {
                    Button("查看完整报告") {
                        sheet = .report(latest)
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.primaryLight)
                }
            }

            LazyVGrid(columns: quickColumns, spacing: 10) {
                ForEach(QuickLink.all) { link in
                    Button {
                        open(link)
                    } label: {
                        quickLinkCell(link)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// 固定列数而不是自适应：自适应在 iPad 上会排成 5 + 3，两行不等宽很难看
    private var quickColumns: [GridItem] {
        let count = sizeClass == .compact ? 2 : 4
        return Array(repeating: GridItem(.flexible(), spacing: 10), count: count)
    }

    private func quickLinkCell(_ link: QuickLink) -> some View {
        let accent = Color(hex: link.accent)
        return HStack(spacing: 10) {
            Image(systemName: link.symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 30, height: 30)
                .background(accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text(link.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                Text(link.subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
        }
    }

    // MARK: - 可信度说明

    private var legendCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "数据可信度", symbol: "checkmark.seal", accent: Theme.success)

                ForEach(Confidence.allCases.reversed(), id: \.rawValue) { level in
                    HStack(spacing: 8) {
                        ConfidenceBadge(confidence: level)
                        Text(description(for: level))
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textSecondary)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    private func description(for level: Confidence) -> String {
        switch level {
        case .verified: return "系统 API 直接读取，可信"
        case .high: return "来源可靠，但非系统直接上报"
        case .inferred: return "由机型库或日志推断，仅供参考"
        case .unavailable: return "受系统限制无法读取，不做猜测"
        }
    }

    private var footer: some View {
        VStack(spacing: 4) {
            Text("所有数据仅在本机处理，不上传、不联网")
                .font(.system(size: 10))
                .foregroundStyle(Theme.textTertiary)
            Text("机型库 \(DeviceCatalog.shared.version)")
                .font(.system(size: 10))
                .foregroundStyle(Theme.textTertiary.opacity(0.7))
        }
        .padding(.top, 4)
    }

    // MARK: - 行为

    @MainActor
    private func scan(deep: DeepScanResult?, save: Bool) async {
        let report = await scanner.run(
            mode: deep == nil ? .standard : .deep,
            catalog: DeviceCatalog.shared,
            deep: deep
        )
        latest = report
        if save {
            store.add(report)
        }
    }

    private func open(_ link: QuickLink) {
        guard let latest else { return }
        if link.key == "report" {
            sheet = .report(latest)
            return
        }
        if let section = latest.section(link.key) {
            sheet = .section(section)
        }
    }

    @ViewBuilder
    private func sheetContent(_ item: HomeSheet) -> some View {
        switch item {
        case .section(let section):
            SectionDetailView(section: section)
        case .report(let report):
            ReportDetailView(report: report)
        case .deepScan:
            DeepScanView { deep in
                sheet = nil
                Task { await scan(deep: deep, save: true) }
            }
        }
    }
}

// MARK: - 辅助类型

private enum HomeSheet: Identifiable {
    case section(ReportSection)
    case report(ScanReport)
    case deepScan

    var id: String {
        switch self {
        case .section(let section): return "section-\(section.key)"
        case .report(let report): return "report-\(report.id.uuidString)"
        case .deepScan: return "deep-scan"
        }
    }
}

struct QuickLink: Identifiable {
    let key: String
    let title: String
    let subtitle: String
    let symbol: String
    let accent: UInt32

    var id: String { key }

    static let all: [QuickLink] = [
        QuickLink(key: "device", title: "设备概览", subtitle: "型号 · 芯片 · 内存", symbol: "iphone.gen3", accent: 0x22D3EE),
        QuickLink(key: "display", title: "屏幕信息", subtitle: "分辨率 · 像素密度", symbol: "display", accent: 0xA855F7),
        QuickLink(key: "battery", title: "电池状态", subtitle: "电量 · 充电 · 健康", symbol: "battery.75percent", accent: 0x34D399),
        QuickLink(key: "power", title: "充电与功率", subtitle: "实测输入 · 效率", symbol: "bolt.fill", accent: 0xFBBF24),
        QuickLink(key: "thermal", title: "温度传感器", subtitle: "全机测温点", symbol: "thermometer.medium", accent: 0xF87171),
        QuickLink(key: "storage", title: "存储分析", subtitle: "容量 · 使用率", symbol: "internaldrive", accent: 0xF59E0B),
        QuickLink(key: "system", title: "系统状态", subtitle: "热状态 · 运行时长", symbol: "cpu", accent: 0x60A5FA),
        QuickLink(key: "report", title: "诊断报告", subtitle: "完整体检报告", symbol: "doc.text.magnifyingglass", accent: 0xF472B6)
    ]
}

#Preview {
    HomeView()
        .preferredColorScheme(.dark)
}
