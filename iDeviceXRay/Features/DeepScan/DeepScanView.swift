import SwiftUI
import UniformTypeIdentifiers

struct DeepScanView: View {
    let onComplete: (DeepScanResult) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var showImporter = false
    @State private var isParsing = false
    @State private var progress: Double = 0
    @State private var stage = ""
    @State private var result: DeepScanResult?
    @State private var errorText = ""
    @State private var showError = false

    var body: some View {
        NavigationStack {
            PageContainer {
                introCard
                importCard

                if isParsing {
                    progressCard
                }

                if let result {
                    resultCard(result)
                }

                limitNote
            }
            .navigationTitle("深度检测")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                        .foregroundStyle(Theme.primaryLight)
                }
            }
            .toolbarBackground(Theme.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: allowedTypes,
                allowsMultipleSelection: false
            ) { outcome in
                handleImport(outcome)
            }
            .alert("无法解析", isPresented: $showError) {
                Button("好", role: .cancel) {}
            } message: {
                Text(errorText)
            }
        }
        .preferredColorScheme(.dark)
    }

    private var allowedTypes: [UTType] {
        var types: [UTType] = []
        if let gz = UTType(filenameExtension: "gz") { types.append(gz) }
        if let tgz = UTType(filenameExtension: "tgz") { types.append(tgz) }
        if let tar = UTType(filenameExtension: "tar") { types.append(tar) }
        if !types.isEmpty { return types }
        return [.data]
    }

    // MARK: - 说明

    private var introCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "如何获取诊断档案", symbol: "questionmark.circle", accent: Theme.cyan)

                step(1, "同时按住「音量 +」「音量 −」和「侧边按钮」约 1.5 秒，屏幕会闪一下")
                step(2, "等待 1–3 分钟，系统在后台生成压缩包")
                step(3, "打开「设置 › 隐私与安全性 › 分析与改进 › 分析数据」")
                step(4, "找到 sysdiagnose 开头的 .tar.gz，分享到「文件」，再从这里导入")

                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 10))
                    Text("档案只在本机解压与解析，不会上传。解析完成后临时文件立即删除。")
                        .font(.system(size: 10))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(Theme.success)
                .padding(.top, 2)
            }
        }
    }

    private func step(_ index: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(index)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.primaryLight)
                .frame(width: 18, height: 18)
                .background(Theme.primary.opacity(0.18), in: Circle())
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    // MARK: - 导入

    private var importCard: some View {
        Button {
            showImporter = true
        } label: {
            VStack(spacing: 10) {
                Image(systemName: "arrow.down.doc")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(Theme.primaryLight)

                Text("选择 sysdiagnose 压缩包")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)

                Text("支持 .tar.gz / .tgz，建议小于 500 MB")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
            .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(
                        Theme.primaryLight.opacity(0.45),
                        style: StrokeStyle(lineWidth: 1, dash: [6, 5])
                    )
            }
        }
        .buttonStyle(.plain)
        .disabled(isParsing)
    }

    private var progressCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("正在解析")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.cyan)
                }

                ProgressView(value: progress)
                    .tint(Theme.primaryLight)

                Text(stage)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }

    // MARK: - 结果

    private func resultCard(_ result: DeepScanResult) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "解析结果", symbol: "checkmark.seal", accent: Theme.success)

                Text(result.fileName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 8) {
                    pill("\(result.entriesScanned) 条目")
                    pill("\(result.matchedFiles.count) 命中")
                    pill(String(format: "%.1fs", result.durationSeconds))
                }

                if result.extraction.isEmpty {
                    Text("没有提取到可用字段。系统版本更新后日志格式可能变化，需要更新解析规则。")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(result.extraction.keys.sorted()), id: \.self) { key in
                            HStack {
                                Text(displayName(key))
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.textSecondary)
                                Spacer()
                                Text(result.extraction[key] ?? "—")
                                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                                    .foregroundStyle(Theme.textPrimary)
                            }
                            .padding(.vertical, 6)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                if let powerlog = result.powerlog, powerlog.hasAnything {
                    PowerlogHistoryCard(summary: powerlog)
                }

                ForEach(result.warnings, id: \.self) { warning in
                    HStack(alignment: .top, spacing: 5) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 9))
                        Text(warning)
                            .font(.system(size: 10))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(Theme.warning)
                }

                Button {
                    onComplete(result)
                } label: {
                    Label("合并到体检报告", systemImage: "square.stack.3d.up")
                }
                .buttonStyle(GradientButtonStyle())
                .padding(.top, 2)
            }
        }
    }

    private func pill(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.white.opacity(0.06), in: Capsule())
    }

    private func displayName(_ key: String) -> String {
        switch key {
        case "battery.cycleCount": return "循环次数"
        case "battery.health": return "健康度"
        case "battery.temperature": return "电池温度"
        case "battery.voltage": return "电池电压"
        case "battery.designCapacity": return "设计容量"
        case "battery.maxCapacity": return "实际最大容量"
        case "battery.historySpan": return "历史记录跨度"
        case "display.panelCode": return "显示组件 ID"
        default: return key
        }
    }

    private var limitNote: some View {
        Text("受 iOS 沙盒限制，「循环次数」「健康度」等字段没有任何公开 API，只能通过系统诊断档案间接获取。解析结果的可信度取决于系统日志是否包含对应记录。")
            .font(.system(size: 10))
            .foregroundStyle(Theme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
    }

    // MARK: - 行为

    private func handleImport(_ outcome: Result<[URL], Error>) {
        switch outcome {
        case .success(let urls):
            guard let url = urls.first else { return }
            start(url)
        case .failure(let error):
            errorText = error.localizedDescription
            showError = true
        }
    }

    private func start(_ url: URL) {
        isParsing = true
        progress = 0
        stage = "准备读取…"
        result = nil

        Task {
            do {
                let parsed = try await DeepScanService.shared.parse(url: url) { value, text in
                    Task { @MainActor in
                        progress = value
                        stage = text
                    }
                }
                await MainActor.run {
                    result = parsed
                    isParsing = false
                    progress = 1
                    stage = "解析完成"
                }
            } catch {
                await MainActor.run {
                    isParsing = false
                    if let localized = error as? LocalizedError, let description = localized.errorDescription {
                        errorText = description
                    } else {
                        errorText = error.localizedDescription
                    }
                    showError = true
                }
            }
        }
    }
}

#Preview {
    DeepScanView { _ in }
        .preferredColorScheme(.dark)
}
