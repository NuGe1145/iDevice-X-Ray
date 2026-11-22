import SwiftUI

// MARK: - 实时标记

struct LiveDot: View {
    var color: Color = Theme.success
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .overlay {
                Circle()
                    .stroke(color.opacity(0.7), lineWidth: 1)
                    .scaleEffect(pulse ? 2.8 : 1)
                    .opacity(pulse ? 0 : 0.9)
            }
            .animation(.easeOut(duration: 1.4).repeatForever(autoreverses: false), value: pulse)
            .onAppear { pulse = true }
    }
}

private enum LiveFormat {
    static func value(_ value: Double?, _ digits: Int) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%.\(digits)f", value)
    }

    static func clock(_ date: Date?) -> String {
        guard let date else { return "—" }
        return formatter.string(from: date)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

// MARK: - 曲线

/// 采样序列折线图。没有数据的点直接跳过、断线，不用 0 补，
/// 因为 0 W 与「通道没工作」必须能看出来是两件事。
struct ChargeSparkline: View {
    let samples: [ChargeSample]
    let metric: ChargeMetric
    var window: TimeInterval = 60
    var accent: Color = Theme.warning
    var showsLabels = true
    var lineWidth: CGFloat = 2

    private var points: [(time: Date, value: Double)] {
        samples.compactMap { sample in
            guard let value = metric.value(sample), value.isFinite else { return nil }
            return (sample.time, value)
        }
    }

    private func domain(_ values: [Double]) -> (lower: Double, upper: Double) {
        guard let low = values.min(), let high = values.max() else { return (0, 1) }
        // 功率与电流带零基线，读数才能看出「有没有在工作」；
        // 温度带零会把曲线压成一条线，所以只围绕自身区间放大。
        var lower = metric == .temperature ? low : min(0, low)
        var upper = metric == .temperature ? high : max(0.5, high)
        let padding = max((upper - lower) * 0.12, 0.05)
        lower -= padding
        upper += padding
        if upper - lower < 0.15 { upper = lower + 0.15 }
        return (lower, upper)
    }

    var body: some View {
        let pts = points
        let values = pts.map(\.value)
        let range = domain(values)
        let end = pts.last?.time ?? Date()
        let start = end.addingTimeInterval(-window)

        Canvas { context, canvasSize in
            guard canvasSize.width > 0, canvasSize.height > 0 else { return }

            // 三条参考线
            for fraction in [0.15, 0.5, 0.85] {
                var line = Path()
                let y = canvasSize.height * fraction
                line.move(to: CGPoint(x: 0, y: y))
                line.addLine(to: CGPoint(x: canvasSize.width, y: y))
                context.stroke(line, with: .color(.white.opacity(0.05)), lineWidth: 1)
            }

            guard pts.count >= 2 else {
                let text = Text(metric == .temperature ? "等待温度读数" : "等待采样")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
                context.draw(text, at: CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2))
                return
            }

            func point(_ time: Date, _ value: Double) -> CGPoint {
                let xRatio = max(0, min(1, time.timeIntervalSince(start) / window))
                let yRatio = max(0, min(1, (value - range.lower) / (range.upper - range.lower)))
                return CGPoint(x: xRatio * canvasSize.width, y: (1 - yRatio) * canvasSize.height)
            }

            let visible = pts.filter { $0.time >= start }
            guard visible.count >= 2 else { return }

            var line = Path()
            for (index, item) in visible.enumerated() {
                let p = point(item.time, item.value)
                if index == 0 { line.move(to: p) } else { line.addLine(to: p) }
            }

            // 面积
            if let first = visible.first, let last = visible.last {
                var area = line
                area.addLine(to: CGPoint(x: point(last.time, last.value).x, y: canvasSize.height))
                area.addLine(to: CGPoint(x: point(first.time, first.value).x, y: canvasSize.height))
                area.closeSubpath()
                context.fill(
                    area,
                    with: .linearGradient(
                        Gradient(colors: [accent.opacity(0.30), accent.opacity(0.02)]),
                        startPoint: CGPoint(x: 0, y: 0),
                        endPoint: CGPoint(x: 0, y: canvasSize.height)
                    )
                )
            }

            context.stroke(
                line,
                with: .linearGradient(
                    Gradient(colors: [accent.opacity(0.7), accent]),
                    startPoint: CGPoint(x: 0, y: 0),
                    endPoint: CGPoint(x: canvasSize.width, y: 0)
                ),
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
            )

            if let last = visible.last {
                let p = point(last.time, last.value)
                let glow = Path(ellipseIn: CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12))
                context.fill(glow, with: .color(accent.opacity(0.22)))
                let dot = Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6))
                context.fill(dot, with: .color(accent))
            }

            if showsLabels {
                let highText = Text("\(LiveFormat.value(range.upper, metric == .temperature ? 1 : 2)) \(metric.unit)")
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
                context.draw(highText, at: CGPoint(x: 2, y: 6), anchor: .topLeading)

                let lowLabel = metric == .temperature ? range.lower : max(range.lower, 0)
                let lowText = Text("\(LiveFormat.value(lowLabel, metric == .temperature ? 1 : 2)) \(metric.unit)")
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
                context.draw(lowText, at: CGPoint(x: 2, y: canvasSize.height - 6), anchor: .bottomLeading)
            }
        }
    }
}

// MARK: - 紧凑状态条（电池 / 温度页用）

@MainActor
struct LiveStatusBar: View {
    var monitor: ChargeMonitor

    var body: some View {
        HStack(spacing: 7) {
            if monitor.isSampling {
                LiveDot()
            } else {
                Circle().fill(Theme.textTertiary).frame(width: 6, height: 6)
            }

            Text(monitor.isPaused ? "已暂停" : "实时")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(monitor.isPaused ? Theme.textSecondary : Theme.success)

            Text("每 \(Int(monitor.refreshInterval)) 秒刷新")
                .font(.system(size: 10))
                .foregroundStyle(Theme.textTertiary)

            Spacer(minLength: 0)

            Text(LiveFormat.clock(monitor.lastUpdate))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Theme.textTertiary)

            Button {
                monitor.isPaused ? monitor.resume() : monitor.pause()
            } label: {
                Image(systemName: monitor.isPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 22, height: 22)
                    .background(Color.white.opacity(0.06), in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.04), in: Capsule())
        .overlay {
            Capsule().strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
        }
    }
}

// MARK: - 充电实时卡

@MainActor
struct ChargeLiveCard: View {
    var monitor: ChargeMonitor
    @State private var metric: ChargeMetric = .power

    private var sample: ChargeSample? { monitor.latest }
    private var connected: Bool { monitor.isConnected }

    var body: some View {
        GlassCard(padding: 16) {
            VStack(alignment: .leading, spacing: 14) {
                header
                headline

                if connected {
                    railGrid
                } else {
                    disconnectedHint
                }

                chart

                if monitor.sessionMilliampHours > 0.5 || monitor.sessionDuration > 0 {
                    sessionRow
                }

                footnote
            }
        }
    }

    // MARK: 头部

    private var header: some View {
        HStack(spacing: 6) {
            if monitor.isSampling {
                LiveDot()
            } else {
                Circle().fill(Theme.textTertiary).frame(width: 6, height: 6)
            }

            Text(monitor.isPaused ? "已暂停" : "实时监控")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(monitor.isPaused ? Theme.textSecondary : Theme.success)

            Text("每 \(Int(monitor.refreshInterval)) 秒")
                .font(.system(size: 10))
                .foregroundStyle(Theme.textTertiary)

            Spacer(minLength: 0)

            Button {
                monitor.isPaused ? monitor.resume() : monitor.pause()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: monitor.isPaused ? "play.fill" : "pause.fill")
                        .font(.system(size: 8, weight: .bold))
                    Text(monitor.isPaused ? "继续" : "暂停")
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.white.opacity(0.06), in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: 主读数

    private var headline: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(mainValue)
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.textPrimary)
                        .contentTransition(.numericText())
                        .animation(.easeOut(duration: 0.18), value: mainValue)
                    Text("W")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.textTertiary)
                }

                Text(mainCaption)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 3) {
                Text(levelText)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                    .contentTransition(.numericText())

                Text(sample?.state.title ?? "状态未知")
                    .font(.system(size: 10))
                    .foregroundStyle(stateColor)
            }
        }
    }

    private var mainValue: String {
        if connected, let watts = sample?.inputWatts {
            return LiveFormat.value(watts, 2)
        }
        if !connected, let watts = sample?.batteryWatts, watts < -0.05 {
            return LiveFormat.value(abs(watts), 2)
        }
        return "—"
    }

    private var mainCaption: String {
        if connected, sample?.inputWatts != nil {
            var text = "USB-C 输入功率"
            if let efficiency {
                text += " · 转进电池 \(efficiencyText(efficiency))"
            }
            return text
        }
        if connected {
            return "已连接电源，输入通道暂未给出读数"
        }
        if let watts = sample?.batteryWatts, watts < -0.05 {
            return "电池放电功率"
        }
        return monitor.isConnected ? "已连接电源" : "未连接电源"
    }

    private var efficiency: Double? {
        guard monitor.isCharging,
              let input = sample?.inputWatts, input > 0.5,
              let battery = sample?.batteryWatts, battery > 0 else { return nil }
        return min(120, battery / input * 100)
    }

    private func efficiencyText(_ value: Double) -> String {
        "\(LiveFormat.value(value, 0))%"
    }

    private var levelText: String {
        guard let level = sample?.level else { return "—" }
        return "\(Int((level * 100).rounded()))%"
    }

    private var stateColor: Color {
        guard let state = sample?.state else { return Theme.textTertiary }
        switch state {
        case .charging: return Theme.success
        case .full: return Theme.cyan
        case .plugged: return Theme.warning
        default: return Theme.textTertiary
        }
    }

    // MARK: 通道

    private var railGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
            railCell("输入电压", sample?.inputVoltage, 2, "V")
            railCell("输入电流", sample?.inputCurrent, 2, "A")
            railCell("电池电压", sample?.batteryVoltage, 2, "V")
            railCell(batteryCurrentTitle, sample?.batteryCurrent?.magnitude, 2, "A")
            railCell("电池温度", sample?.batteryTemperature, 1, "°C")
            railCell("充电 IC", sample?.chargerTemperature, 1, "°C")
        }
    }

    /// 有符号电流：正为充入，负为放电。读不到时用中性标题，别声称「充入」。
    private var batteryCurrentTitle: String {
        guard let value = sample?.batteryCurrent else { return "电池电流" }
        return value >= 0 ? "充入电流" : "放电电流"
    }

    private func railCell(_ title: String, _ value: Double?, _ digits: Int, _ unit: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(Theme.textTertiary)

            Spacer(minLength: 4)

            Text(LiveFormat.value(value, digits))
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(value == nil ? Theme.textTertiary : Theme.textPrimary)
                .contentTransition(.numericText())

            Text(unit)
                .font(.system(size: 9))
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var disconnectedHint: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "powerplug")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
            Text("未连接电源，输入通道不工作，因此不显示 0 V / 0 W。插上后会立即开始记录，无需重新扫描。")
                .font(.system(size: 10))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: 曲线

    private var chart: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("最近 60 秒")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)

                Spacer(minLength: 0)

                Picker("指标", selection: $metric) {
                    ForEach(ChargeMetric.allCases, id: \.self) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 168)
                .scaleEffect(0.9)
            }

            ChargeSparkline(
                samples: monitor.samples,
                metric: metric,
                window: 60,
                accent: accentColor
            )
            .frame(height: 88)

            HStack(spacing: 10) {
                Text("最低 \(LiveFormat.value(windowStats.minimum, metric == .temperature ? 1 : 2)) \(metric.unit)")
                Text("平均 \(LiveFormat.value(windowStats.average, metric == .temperature ? 1 : 2)) \(metric.unit)")
                Text("最高 \(LiveFormat.value(windowStats.maximum, metric == .temperature ? 1 : 2)) \(metric.unit)")
                Spacer(minLength: 0)
                Text("\(windowStats.count) 点")
            }
            .font(.system(size: 9, design: .monospaced))
            .foregroundStyle(Theme.textTertiary)
        }
    }

    private var windowStats: ChargeStats {
        monitor.stats(metric, seconds: 60)
    }

    private var accentColor: Color {
        switch metric {
        case .power: return Theme.warning
        case .current: return Theme.cyan
        case .temperature: return Theme.danger
        }
    }

    // MARK: 本次统计

    private var sessionRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 0) {
                sessionStat("已充入", "\(Int(monitor.sessionMilliampHours.rounded())) mAh")
                sessionStat("电量", String(format: "%.2f Wh", monitor.sessionWattHours))
                sessionStat("峰值", "\(LiveFormat.value(monitor.sessionPeakWatts, 2)) W")
                sessionStat("时长", LiveFormat.duration(monitor.sessionDuration))
            }

            HStack(spacing: 6) {
                Image(systemName: "sum")
                    .font(.system(size: 8))
                Text("按每秒电流积分得出，仅在检测到充电时累计")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.textTertiary)
                Spacer(minLength: 0)
                Button("清零") { monitor.resetSession() }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.primaryLight)
            }
        }
        .padding(10)
        .background(Theme.warning.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.warning.opacity(0.16), lineWidth: 1)
        }
    }

    private func sessionStat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(title)
                .font(.system(size: 9))
                .foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 底部

    private var footnote: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text("采样 \(monitor.sampleCount) 次")
                Text("·")
                Text("最近更新 \(LiveFormat.clock(monitor.lastUpdate))")
                Spacer(minLength: 0)
                if monitor.hidFailures > 0 {
                    Text("HID 失败 \(monitor.hidFailures) 次")
                        .foregroundStyle(Theme.warning)
                }
            }
            .font(.system(size: 9, design: .monospaced))
            .foregroundStyle(Theme.textTertiary)

            if monitor.isPaused {
                Text("已暂停采样，显示的是暂停前最后一次读数。")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }
}

// MARK: - 首页充电条

@MainActor
struct ChargeLiveStrip: View {
    var monitor: ChargeMonitor
    var onTap: () -> Void

    private var sample: ChargeSample? { monitor.latest }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 11) {
                ZStack {
                    Circle()
                        .fill(Theme.warning.opacity(0.14))
                        .frame(width: 34, height: 34)
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.warning)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(sample?.state.title ?? "已连接电源")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)

                        if monitor.isSampling {
                            LiveDot(color: Theme.warning)
                        }

                        Text(wattsText)
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.warning)
                            .contentTransition(.numericText())
                    }

                    Text(detailText)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                ChargeSparkline(
                    samples: monitor.samples,
                    metric: .power,
                    window: 60,
                    accent: Theme.warning,
                    showsLabels: false,
                    lineWidth: 1.5
                )
                .frame(width: 56, height: 28)

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Theme.warning.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Theme.warning.opacity(0.18), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    private var wattsText: String {
        guard let watts = sample?.inputWatts else { return "— W" }
        return "\(LiveFormat.value(watts, 2)) W"
    }

    private var detailText: String {
        var parts: [String] = []
        if let voltage = sample?.inputVoltage, let current = sample?.inputCurrent {
            parts.append(String(format: "%.2f V × %.2f A", voltage, current))
        }
        if let level = sample?.level {
            parts.append("电池 \(Int((level * 100).rounded()))%")
        }
        if let temp = sample?.batteryTemperature {
            parts.append(String(format: "%.1f °C", temp))
        }
        if parts.isEmpty { return "点开查看实时功率与温度" }
        return parts.joined(separator: " · ")
    }
}

// MARK: - 预览

#Preview {
    VStack(spacing: 14) {
        LiveStatusBar(monitor: ChargeMonitor.shared)
        ChargeLiveCard(monitor: ChargeMonitor.shared)
    }
    .padding()
    .background(ScreenBackground())
    .preferredColorScheme(.dark)
}
