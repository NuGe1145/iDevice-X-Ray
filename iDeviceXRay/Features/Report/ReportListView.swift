import SwiftUI

struct ReportListView: View {
    @State private var store = ReportStore.shared
    @State private var selected: ScanReport?

    var body: some View {
        NavigationStack {
            ZStack {
                ScreenBackground()

                if store.reports.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(store.reports) { report in
                            Button {
                                selected = report
                            } label: {
                                row(report)
                            }
                            .buttonStyle(.plain)
                            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    store.delete(report)
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("报告")
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(Theme.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .sheet(item: $selected) { report in
                ReportDetailView(report: report)
            }
        }
    }

    private func row(_ report: ScanReport) -> some View {
        HStack(spacing: 12) {
            VStack(spacing: 0) {
                Text("\(report.completenessScore)")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.primaryLight)
                Text("%")
                    .font(.system(size: 8))
                    .foregroundStyle(Theme.textTertiary)
            }
            .frame(width: 44, height: 44)
            .background(Theme.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(report.deviceName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    if report.mode == .deep {
                        Text("深度")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Theme.cyan)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Theme.cyan.opacity(0.14), in: Capsule())
                    }
                }
                Text("\(Format.dateTime(report.createdAt)) · \(report.readableCount)/\(report.totalCount) 项可读")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(14)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(Theme.textTertiary)

            Text("还没有报告")
                .font(.system(.headline, design: .rounded))
                .foregroundStyle(Theme.textPrimary)

            Text("在首页点击「标准检测」或「深度检测」，\n完成一次扫描后报告会保存在这里。")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(32)
    }
}

#Preview {
    ReportListView()
        .preferredColorScheme(.dark)
}
