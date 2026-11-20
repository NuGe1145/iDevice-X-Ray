import SwiftUI
import UIKit

struct ReportDetailView: View {
    let report: ScanReport
    @Environment(\.dismiss) private var dismiss

    @State private var expanded: Set<String> = []
    @State private var shareItems: [Any] = []
    @State private var showShare = false
    @State private var alertText = ""
    @State private var showAlert = false

    var body: some View {
        NavigationStack {
            PageContainer {
                coverCard

                ForEach(report.sections) { section in
                    sectionCard(section)
                }

                if let deep = report.deep {
                    deepCard(deep)
                }

                actionRow
                disclaimer
            }
            .navigationTitle("体检报告")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                        .foregroundStyle(Theme.primaryLight)
                }
            }
            .toolbarBackground(Theme.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .sheet(isPresented: $showShare) {
                ActivityView(items: shareItems)
                    .presentationDetents([.medium, .large])
            }
            .alert("提示", isPresented: $showAlert) {
                Button("好", role: .cancel) {}
            } message: {
                Text(alertText)
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - 封面

    private var coverCard: some View {
        GlassCard(padding: 20) {
            HStack(spacing: 18) {
                ZStack {
                    GlowRing(progress: Double(report.completenessScore) / 100, size: 84, lineWidth: 7, showsGlow: false)
                    VStack(spacing: 0) {
                        Text("\(report.completenessScore)")
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.textPrimary)
                        Text("%")
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text(report.deviceName)
                        .font(.system(size: 19, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.textPrimary)
                    Text("\(report.identifier) · iOS \(report.osVersion)")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                    Text("\(report.mode.displayName) · \(Format.dateTime(report.createdAt))")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                }

                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                miniStat("\(report.totalCount)", "检测项", Theme.cyan)
                miniStat("\(report.readableCount)", "可读", Theme.success)
                miniStat("\(report.verifiedCount)", "已验证", Theme.primaryLight)
            }
            .padding(.top, 14)
        }
    }

    private func miniStat(_ value: String, _ title: String, _ accent: Color) -> some View {
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

    // MARK: - 分区

    private func sectionCard(_ section: ReportSection) -> some View {
        let isOpen = expanded.contains(section.key)
        let accent = Color(hex: section.accentHex)

        return GlassCard(padding: 0) {
            VStack(spacing: 0) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if isOpen {
                            expanded.remove(section.key)
                        } else {
                            _ = expanded.insert(section.key)
                        }
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: section.symbol)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(accent)
                            .frame(width: 30, height: 30)
                            .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

                        VStack(alignment: .leading, spacing: 1) {
                            Text(section.title)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary)
                            Text(sectionSubtitle(section))
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.textTertiary)
                        }

                        Spacer(minLength: 0)

                        Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .padding(14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isOpen {
                    VStack(spacing: 0) {
                        ForEach(Array(section.fields.enumerated()), id: \.element.id) { index, field in
                            FieldRow(field: field)
                            if index < section.fields.count - 1 {
                                Rectangle()
                                    .fill(Color.white.opacity(0.05))
                                    .frame(height: 1)
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
                }
            }
        }
    }

    /// 充电、温度、电池在详情页是实时刷新的，报告里存的只是扫描那一刻的值，
    /// 不标出来用户会以为报告里的数字没更新是坏了。
    private func sectionSubtitle(_ section: ReportSection) -> String {
        let base = "\(section.readableCount) / \(section.fields.count) 项可读"
        let liveKeys = ["power", "thermal", "battery"]
        return liveKeys.contains(section.key) ? base + " · 扫描时快照" : base
    }

    // MARK: - 深度数据

    private func deepCard(_ deep: DeepScanResult) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "深度数据来源", symbol: "doc.text.magnifyingglass", accent: Theme.cyan)

                Text(deep.fileName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)

                HStack(spacing: 12) {
                    if deep.directDatabase == true {
                        infoPill("直读数据库")
                    } else {
                        infoPill("\(deep.entriesScanned) 条目")
                        infoPill("\(deep.matchedFiles.count) 命中")
                    }
                    infoPill(String(format: "%.1fs", deep.durationSeconds))
                }

                ForEach(deep.warnings, id: \.self) { warning in
                    HStack(alignment: .top, spacing: 5) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 9))
                        Text(warning)
                            .font(.system(size: 10))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(Theme.warning)
                }
            }
        }
    }

    private func infoPill(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.white.opacity(0.06), in: Capsule())
    }

    // MARK: - 操作

    private var actionRow: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    exportPDF()
                } label: {
                    Label("导出 PDF", systemImage: "doc.richtext")
                }
                .buttonStyle(GhostButtonStyle())

                Button {
                    exportJSON()
                } label: {
                    Label("导出 JSON", systemImage: "curlybraces")
                }
                .buttonStyle(GhostButtonStyle())
            }

            Button {
                shareCard()
            } label: {
                Label("生成分享长图", systemImage: "photo.on.rectangle")
            }
            .buttonStyle(GradientButtonStyle())
        }
    }

    private var disclaimer: some View {
        Text("报告是扫描那一刻的快照：充电功率、电压、温度、电量等会随时间变化，实时数据请从首页进入对应分区查看。标记为「不可读取」的项目代表本机确实无法取得该数据，未使用任何估算值填充。健康度等指标仅供参照，不能作为维修或交易的唯一依据。")
            .font(.system(size: 10))
            .foregroundStyle(Theme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
    }

    // MARK: - 导出实现

    private func exportPDF() {
        guard let data = ReportExporter.pdfData(for: report) else {
            present("PDF 生成失败，请重试")
            return
        }
        let name = "iDeviceXRay-\(report.deviceName)-\(fileStamp()).pdf"
        guard let url = ReportExporter.temporaryFile(named: name, data: data) else {
            present("无法写入临时文件")
            return
        }
        shareItems = [url]
        showShare = true
    }

    private func exportJSON() {
        guard let data = ReportExporter.jsonData(for: report) else {
            present("JSON 生成失败")
            return
        }
        let name = "iDeviceXRay-\(report.deviceName)-\(fileStamp()).json"
        guard let url = ReportExporter.temporaryFile(named: name, data: data) else {
            present("无法写入临时文件")
            return
        }
        shareItems = [url]
        showShare = true
    }

    private func shareCard() {
        guard let image = ReportExporter.shareImage(for: report) else {
            present("长图生成失败")
            return
        }
        shareItems = [image]
        showShare = true
    }

    private func fileStamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return formatter.string(from: Date())
    }

    private func present(_ message: String) {
        alertText = message
        showAlert = true
    }
}

// MARK: - 系统分享面板

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
