import SwiftUI

struct DeepScanView: View {
    let initialURL: URL?
    let onComplete: (DeepScanResult) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var isParsing = false
    @State private var progress: Double = 0
    @State private var stage = ""
    @State private var result: DeepScanResult?
    @State private var errorText = ""
    @State private var showError = false
    @State private var didAutoStart = false
    @State private var localFiles: [LocalImportCandidate] = []

    init(initialURL: URL? = nil, onComplete: @escaping (DeepScanResult) -> Void) {
        self.initialURL = initialURL
        self.onComplete = onComplete
    }

    var body: some View {
        NavigationStack {
            PageContainer {
                introCard
                importCard

                if !localFiles.isEmpty {
                    localFilesCard
                }

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
        }
        // 不用 SwiftUI 的 .fileImporter：这个页面本身是从 sheet 里弹出来的，
        // 再往上一层呈现选择器，iPad 上会出现「文件能看见、点了一点反应没有」。
        // 改由 UIViewController 直接 present，见 DocumentImporter。
        .alert("无法解析", isPresented: $showError) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorText)
        }
        .task {
            await refreshLocalFiles()
            guard !didAutoStart, let initialURL else { return }
            didAutoStart = true
            start(initialURL)
        }
        .onChange(of: scenePhase) { _, phase in
            // 用户去「文件」里放好文件再切回来，列表要能立刻看到
            if phase == .active {
                Task { await refreshLocalFiles() }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - 说明

    private var introCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "如何获取诊断档案", symbol: "questionmark.circle", accent: Theme.cyan)

                Text("可选步骤。不导入也能看到实时数据和本机历史；导入之后才有安装前的记录与系统原始循环次数。")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                step(1, "同时按住「音量 +」「音量 −」和「侧边按钮」约 1.5 秒，屏幕会闪一下")
                step(2, "等待 1–3 分钟，系统在后台生成压缩包")
                step(3, "打开「设置 › 隐私与安全性 › 分析与改进 › 分析数据」")
                step(4, "点开 sysdiagnose 开头的条目，右上角分享 → 存储到「文件」")
                step(5, "回到这里选中那个 .tar.gz 导入")

                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "arrow.down.doc")
                        .font(.system(size: 10))
                    Text("更轻的方式：在电脑上解压诊断包，只取 logs/powerlogs/CurrentPowerlog.PLSQL，AirDrop 到手机直接导入。内容与整包一致（未落盘的 -wal 记录同样读不到）。")
                        .font(.system(size: 10))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(Theme.textTertiary)
                .padding(.top, 2)

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
            startPicking()
        } label: {
            VStack(spacing: 10) {
                Image(systemName: "arrow.down.doc")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(Theme.primaryLight)

                Text("选择诊断档案")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)

                Text("整包 .tar.gz 或单独取出的 Powerlog 数据库，建议小于 500 MB")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
                    .multilineTextAlignment(.center)

                Text("也可以在「文件」里长按文件 → 共享 → iDevice X-Ray")
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

    /// 兜底入口：不经过系统选择器，直接读 App 自己的 Documents 目录。
    /// 用户把文件放进「我的 iPhone / iPad → iDevice X-Ray」就会出现在这里。
    private var localFilesCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    SectionHeader(title: "App 文件夹里找到的文件", symbol: "folder.fill", accent: Theme.cyan)
                    Spacer()
                    Button {
                        Task { await refreshLocalFiles() }
                    } label: {
                        Text("刷新")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Theme.cyan)
                    }
                }

                Text("在「文件」App 的「我的 iPhone / iPad → iDevice X-Ray」里放下 sysdiagnose，这里会直接列出来，点一下就开始解析。")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(localFiles) { file in
                    Button {
                        start(file.url)
                    } label: {
                        HStack(spacing: 9) {
                            Image(systemName: "doc.zipper")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.cyan)
                                .frame(width: 16)

                            VStack(alignment: .leading, spacing: 1) {
                                Text(file.name)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(Theme.textPrimary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text(file.sizeText)
                                    .font(.system(size: 9))
                                    .foregroundStyle(Theme.textTertiary)
                            }

                            Spacer(minLength: 4)

                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Theme.textTertiary)
                        }
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isParsing)
                }
            }
        }
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
                    if result.directDatabase == true {
                        pill("直读数据库")
                    } else {
                        pill("\(result.entriesScanned) 条目")
                        pill("\(result.matchedFiles.count) 命中")
                    }
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

    private func handleImport(_ outcome: Result<URL, Error>) {
        switch outcome {
        case .success(let url):
            start(url)
        case .failure(let error):
            errorText = error.localizedDescription
            showError = true
        }
    }

    private func startPicking() {
        DocumentImporter.shared.present { outcome in
            handleImport(outcome)
        }
    }

    /// 扫 Documents 目录可能要读几十个文件的头，放到后台，别卡住首屏
    private func refreshLocalFiles() async {
        let files = await Task.detached(priority: .utility) {
            LocalImportFolder.candidates()
        }.value
        localFiles = files
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
