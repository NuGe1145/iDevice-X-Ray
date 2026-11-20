import SwiftUI

/// 本机长期历史卡片。
///
/// 这一块是完全自给自足的：不需要 sysdiagnose、不需要越狱、不需要任何账号，
/// 只用 App 自己在后台采样得到的充电数据。代价是历史从安装那天算起。
@MainActor
struct LocalHistoryCard: View {

    @State private var store = BatteryHistoryStore.shared

    private var designMah: Int? {
        DeviceCatalog.shared.spec(for: DeviceIdentity.identifier)?.batteryDesignMah
    }

    private var estimate: CapacityEstimate? { store.capacityEstimate }
    private var health: Double? { store.healthPercent(designMah: designMah) }
    private var days: [DailyBatteryRecord] { store.recentDays(14) }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                header

                if store.recordedDayCount == 0 {
                    emptyState
                } else {
                    metrics
                    bars
                    footnote
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.success)
                .frame(width: 32, height: 32)
                .background(Theme.success.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text("本机历史")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
            }

            Spacer(minLength: 0)
        }
    }

    private var subtitle: String {
        guard let first = store.firstRecordDate else { return "无需导入任何文件，采样即记录" }
        return "从 \(first.formatted(date: .abbreviated, time: .omitted)) 开始"
    }

    private var metrics: some View {
        HStack(spacing: 0) {
            metric(
                title: "记录",
                value: "\(store.recordedDayCount)",
                unit: "天",
                tint: Theme.cyan
            )
            divider
            metric(
                title: "实测容量",
                value: estimate.map { "\(Int($0.milliampereHours.rounded()))" } ?? "—",
                unit: estimate == nil ? nil : "mAh",
                tint: Theme.success
            )
            divider
            metric(
                title: "健康度",
                value: health.map { String(format: "%.0f", $0) } ?? "—",
                unit: health == nil ? nil : "%",
                tint: healthTint
            )
        }
    }

    private func metric(title: String, value: String, unit: String?, tint: Color) -> some View {
        VStack(spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundStyle(tint)
                    .contentTransition(.numericText())
                if let unit {
                    Text(unit)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.06))
            .frame(width: 1, height: 26)
    }

    private var bars: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("近 14 天充电时长")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
                Spacer(minLength: 0)
                Text(String(format: "%.1f h", days.reduce(0) { $0 + $1.chargingSeconds } / 3600))
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
            }

            HStack(alignment: .bottom, spacing: 3) {
                ForEach(days) { day in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Theme.success.opacity(day.chargingSeconds > 0 ? 0.75 : 0.12))
                        .frame(height: barHeight(day))
                        .frame(maxWidth: .infinity)
                        .help(day.dayKey)
                }
            }
            .frame(height: 34, alignment: .bottom)
        }
    }

    private func barHeight(_ day: DailyBatteryRecord) -> CGFloat {
        let peak = max(days.map(\.chargingSeconds).max() ?? 0, 1)
        let ratio = day.chargingSeconds / peak
        return max(3, CGFloat(ratio) * 34)
    }

    private var footnote: some View {
        Text(estimate == nil
             ? "完成一次连续 20% 以上的充电后，这里会给出实测容量与健康度估算。"
             : "容量由电池端电流对时间积分，再除以这段充电的电量变化；取多次中位数，误差约 ±5%。数据只在本机，不上传。")
            .font(.system(size: 10))
            .foregroundStyle(Theme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var emptyState: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "battery.25percent")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
            Text("还没有历史。打开「充电」页并保持充电，App 会按天记录电量、温度与充入电量，不需要做任何导出。")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var healthTint: Color {
        guard let health else { return Theme.textTertiary }
        if health >= 90 { return Theme.success }
        if health >= 80 { return Theme.warning }
        return Theme.danger
    }
}

#Preview {
    LocalHistoryCard()
        .padding()
        .background(Theme.background)
        .preferredColorScheme(.dark)
}
