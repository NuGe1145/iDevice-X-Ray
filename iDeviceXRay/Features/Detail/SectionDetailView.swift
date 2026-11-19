import SwiftUI

struct SectionDetailView: View {
    let section: ReportSection
    @Environment(\.dismiss) private var dismiss

    private var accent: Color { Color(hex: section.accentHex) }

    var body: some View {
        NavigationStack {
            PageContainer {
                summaryCard

                GlassCard {
                    VStack(spacing: 0) {
                        ForEach(Array(section.fields.enumerated()), id: \.element.id) { index, field in
                            FieldRow(field: field)
                            if index < section.fields.count - 1 {
                                Rectangle()
                                    .fill(Color.white.opacity(0.06))
                                    .frame(height: 1)
                            }
                        }
                    }
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
                    Text("\(section.readableCount) / \(section.fields.count) 项可读取")
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
            Image(systemName: "hand.tap")
                .font(.system(size: 11))
            Text("点击任意一行，可查看该项数据的来源与说明。标为「不可读取」的项目，本机确实拿不到，我们不会用估算值填充。")
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Theme.textTertiary)
        .padding(.horizontal, 4)
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
