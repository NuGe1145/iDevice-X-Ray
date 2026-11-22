import SwiftUI

/// 电池历史卡：Powerlog 解析结果的展示层。
/// 只画解出来的点，没有数据的档位直接隐藏，不画空坐标轴。
@MainActor
struct PowerlogHistoryCard: View {

    let summary: PowerlogSummary
    @State private var metric: Metric = .capacity

    private enum Metric: String, CaseIterable {
        case capacity
        case temperature

        var title: String { self == .capacity ? "容量" : "温度" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            HStack(spacing: 0) {
                statTile(value: summary.spanDays.map { "\($0)" } ?? "—", unit: "天", caption: "覆盖时长")
                divider
                statTile(value: summary.cycleCount.map { "\($0)" } ?? "—", unit: "次", caption: "循环次数")
                divider
                statTile(value: summary.rowCount > 0 ? "\(summary.rowCount)" : "—", unit: "条", caption: "采样记录")
            }

            if !availableMetrics.isEmpty {
                chartBlock
            } else {
                Text("表里没有可用的容量或温度列，只解出了上面的标量值。")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(footnote)
                .font(.system(size: 9))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            // 命中的表与列直接摊在这里。列名对不上时，这张卡片本身就是诊断信息，
            // 不必让用户去翻报告 JSON。
            if !summary.matchedColumns.isEmpty {
                Text(summary.matchedColumns.prefix(6).joined(separator: " · "))
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary.opacity(0.8))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Theme.cyan.opacity(0.16), lineWidth: 1)
        }
        .onAppear(perform: pickDefaultMetric)
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "chart.xyaxis.line")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.cyan)

            Text("电池历史")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)

            Spacer(minLength: 0)

            Text(summary.table)
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func statTile(value: String, unit: String, caption: String) -> some View {
        VStack(spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                    .monospacedDigit()
                Text(unit)
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.textTertiary)
            }
            Text(caption)
                .font(.system(size: 9))
                .foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.06))
            .frame(width: 1, height: 22)
    }

    // MARK: - 曲线

    private var availableMetrics: [Metric] {
        var result: [Metric] = []
        if summary.capacitySeries.count >= 2 { result.append(.capacity) }
        if summary.temperatureSeries.count >= 2 { result.append(.temperature) }
        return result
    }

    private var points: [PowerlogSummary.Point] {
        metric == .capacity ? summary.capacitySeries : summary.temperatureSeries
    }

    private var accent: Color {
        metric == .capacity ? Theme.cyan : Theme.warning
    }

    private var unit: String {
        metric == .capacity ? summary.capacityUnit : "°C"
    }

    private func digits() -> Int {
        metric == .capacity ? 0 : 1
    }

    private var chartBlock: some View {
        VStack(spacing: 8) {
            HStack {
                if availableMetrics.count > 1 {
                    HStack(spacing: 2) {
                        ForEach(availableMetrics, id: \.self) { item in
                            Button {
                                withAnimation(.easeInOut(duration: 0.18)) { metric = item }
                            } label: {
                                Text(item.title)
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(metric == item ? Theme.textPrimary : Theme.textTertiary)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 3)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .fill(metric == item ? Color.white.opacity(0.14) : Color.clear)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(2)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    Text(metric.title)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary)
                }

                Spacer(minLength: 0)

                if let first = points.first, let last = points.last {
                    Text("\(Self.shortDate(first.time)) → \(Self.shortDate(last.time))")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Theme.textTertiary)
                }
            }

            PowerlogChart(points: points, unit: unit, accent: accent, digits: digits())
                .frame(height: 84)

            if let stats = stats {
                HStack(spacing: 10) {
                    Text("最低 \(Self.format(stats.min, digits: digits()))\(unit)")
                    Text("平均 \(Self.format(stats.avg, digits: digits()))\(unit)")
                    Text("最高 \(Self.format(stats.max, digits: digits()))\(unit)")
                    Spacer(minLength: 0)
                    Text("\(points.count) 点")
                }
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Theme.textTertiary)
            }
        }
    }

    private var stats: (min: Double, avg: Double, max: Double)? {
        let values = points.map(\.value).filter { $0.isFinite }
        guard !values.isEmpty else { return nil }
        let sum = values.reduce(0, +)
        return (values.min() ?? 0, sum / Double(values.count), values.max() ?? 0)
    }

    private var footnote: String {
        var parts: [String] = []
        if let design = summary.designCapacity {
            parts.append("设计容量 \(design) mAh")
        }
        if let maxCapacity = summary.maxCapacity {
            parts.append("记录到的最大容量 \(maxCapacity) mAh")
        }
        if let health = summary.healthPercent {
            parts.append(String(format: "对应健康度 %.0f%%", health))
        }
        let head = parts.isEmpty ? "只解出时间序列，没有容量与循环字段" : parts.joined(separator: " · ")
        return head + "。数据来自 powerlogd 写入的 Powerlog 数据库，不是当下读数。"
    }

    private func pickDefaultMetric() {
        if summary.capacitySeries.count < 2, summary.temperatureSeries.count >= 2 {
            metric = .temperature
        }
    }

    static func format(_ value: Double, digits: Int) -> String {
        String(format: "%.\(digits)f", value)
    }

    static func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MM-dd"
        return formatter.string(from: date)
    }
}

/// 折线 + 面积渐变。点数已由解析层抽稀到 90 以内，这里不做二次采样。
private struct PowerlogChart: View {
    let points: [PowerlogSummary.Point]
    let unit: String
    let accent: Color
    let digits: Int

    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                guard size.width > 1, size.height > 1 else { return }

                for fraction in [0.2, 0.5, 0.8] {
                    var line = Path()
                    line.move(to: CGPoint(x: 0, y: size.height * fraction))
                    line.addLine(to: CGPoint(x: size.width, y: size.height * fraction))
                    context.stroke(line, with: .color(.white.opacity(0.05)), lineWidth: 1)
                }

                guard points.count >= 2 else { return }

                let values = points.map(\.value)
                let lower = (values.min() ?? 0) - 0.5
                let upper = (values.max() ?? 1) + 0.5
                let span = max(upper - lower, 0.001)

                func position(_ index: Int) -> CGPoint {
                    let x = size.width * CGFloat(index) / CGFloat(points.count - 1)
                    let ratio = (points[index].value - lower) / span
                    return CGPoint(x: x, y: size.height * (1 - CGFloat(ratio)))
                }

                var line = Path()
                for index in points.indices {
                    let point = position(index)
                    if index == 0 { line.move(to: point) } else { line.addLine(to: point) }
                }

                var area = line
                if let last = points.indices.last {
                    area.addLine(to: CGPoint(x: position(last).x, y: size.height))
                    area.addLine(to: CGPoint(x: position(0).x, y: size.height))
                }
                area.closeSubpath()
                context.fill(
                    area,
                    with: .linearGradient(
                        Gradient(colors: [accent.opacity(0.26), accent.opacity(0.01)]),
                        startPoint: .zero,
                        endPoint: CGPoint(x: 0, y: size.height)
                    )
                )

                context.stroke(
                    line,
                    with: .color(accent),
                    style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round)
                )

                if let last = points.indices.last {
                    let point = position(last)
                    context.fill(
                        Path(ellipseIn: CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10)),
                        with: .color(accent.opacity(0.22))
                    )
                    context.fill(
                        Path(ellipseIn: CGRect(x: point.x - 2.4, y: point.y - 2.4, width: 4.8, height: 4.8)),
                        with: .color(accent)
                    )
                }

                let style = Text("\(String(format: "%.\(digits)f", upper)) \(unit)")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
                context.draw(style, at: CGPoint(x: 2, y: 6), anchor: .topLeading)

                let low = Text("\(String(format: "%.\(digits)f", max(lower, 0))) \(unit)")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
                context.draw(low, at: CGPoint(x: 2, y: size.height - 6), anchor: .bottomLeading)

                _ = geo.size
            }
        }
    }
}
