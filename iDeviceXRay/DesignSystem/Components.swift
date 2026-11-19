import SwiftUI

// MARK: - 背景

struct ScreenBackground: View {
    var body: some View {
        ZStack {
            Theme.backgroundGradient
            RadialGradient(
                colors: [Theme.primary.opacity(0.42), .clear],
                center: UnitPoint(x: 0.5, y: 0.02),
                startRadius: 24,
                endRadius: 540
            )
            StarField()
        }
        .ignoresSafeArea()
    }
}

struct StarField: View {
    private let points: [(x: Double, y: Double, r: Double)] = (0..<80).map { index in
        (
            Double((index * 37) % 97) / 97.0,
            Double((index * 53) % 89) / 89.0,
            0.8 + Double(index % 4) * 0.35
        )
    }

    var body: some View {
        Canvas { context, size in
            for point in points {
                let rect = CGRect(
                    x: point.x * size.width,
                    y: point.y * size.height,
                    width: point.r,
                    height: point.r
                )
                context.fill(Path(ellipseIn: rect), with: .color(.white.opacity(0.32)))
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - 卡片

struct GlassCard<Content: View>: View {
    let padding: CGFloat
    let content: Content

    init(padding: CGFloat = 16, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                            .fill(Color.white.opacity(0.02))
                    }
            }
            .overlay {
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.24), Color.white.opacity(0.04)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            }
    }
}

// MARK: - 标题

struct SectionHeader: View {
    let title: String
    let symbol: String
    let accent: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(accent)
            Text(title)
                .font(.system(.headline, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - 可信度

struct ConfidenceBadge: View {
    let confidence: Confidence

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: confidence.symbolName)
                .font(.system(size: 8, weight: .bold))
            Text(confidence.displayName)
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(color.opacity(0.14), in: Capsule())
    }

    private var color: Color {
        switch confidence {
        case .verified: return Theme.success
        case .high: return Theme.cyan
        case .inferred: return Theme.warning
        case .unavailable: return Theme.textTertiary
        }
    }
}

// MARK: - 字段行

struct FieldRow: View {
    let field: ReportField
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(field.title)
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)

                Spacer(minLength: 8)

                Text(field.displayValue)
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundStyle(field.confidence == .unavailable ? Theme.textTertiary : Theme.textPrimary)
                    .multilineTextAlignment(.trailing)
            }

            if expanded, let note = field.footnote {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: field.source.symbolName)
                        .font(.system(size: 9))
                    Text(note)
                        .font(.system(size: 11))
                }
                .foregroundStyle(Theme.textTertiary)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
        }
    }
}

// MARK: - 指标块

struct StatTile: View {
    let value: String
    let unit: String?
    let title: String
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let unit, !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(accent.opacity(0.22), lineWidth: 1)
        }
    }
}

// MARK: - 扫描环

struct GlowRing: View {
    var progress: Double
    var size: CGFloat
    var lineWidth: CGFloat = 10
    var showsGlow: Bool = true

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.07), lineWidth: lineWidth)

            Circle()
                .trim(from: 0, to: max(0.002, min(progress, 1)))
                .stroke(
                    Theme.accentGradient,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .shadow(color: showsGlow ? Theme.primaryLight.opacity(0.65) : .clear, radius: 10)
                .animation(.easeInOut(duration: 0.35), value: progress)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - 按钮

struct GradientButtonStyle: ButtonStyle {
    var colors: [Color] = [Theme.primary, Theme.primaryLight]

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.subheadline, design: .rounded).weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(
                LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .opacity(configuration.isPressed ? 0.82 : 1)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
    }
}

struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.subheadline, design: .rounded).weight(.medium))
            .foregroundStyle(Theme.textPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
            }
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

// MARK: - 页面容器

struct PageContainer<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                content
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 32)
            .frame(maxWidth: Theme.contentMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .background(ScreenBackground())
    }
}
