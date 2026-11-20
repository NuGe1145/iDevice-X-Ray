import SwiftUI
import UIKit

// MARK: - 导出

@MainActor
enum ReportExporter {

    static func jsonData(for report: ScanReport) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try? encoder.encode(report)
    }

    static func pdfData(for report: ScanReport) -> Data? {
        let pageWidth: CGFloat = 595 // A4 宽度（pt）
        let renderer = ImageRenderer(content: ReportDocumentView(report: report).frame(width: pageWidth))
        renderer.scale = 2

        guard let image = renderer.uiImage else { return nil }
        let pageSize = CGSize(width: pageWidth, height: image.size.height)

        let data = NSMutableData()
        UIGraphicsBeginPDFContextToData(data, CGRect(origin: .zero, size: pageSize), nil)
        UIGraphicsBeginPDFPage()
        image.draw(in: CGRect(origin: .zero, size: pageSize))
        UIGraphicsEndPDFContext()

        return data as Data
    }

    static func shareImage(for report: ScanReport) -> UIImage? {
        let width: CGFloat = 375
        let renderer = ImageRenderer(content: ReportShareCard(report: report).frame(width: width))
        renderer.scale = 3
        return renderer.uiImage
    }

    static func temporaryFile(named name: String, data: Data) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}

// MARK: - PDF 文档视图
// 注意：离屏渲染使用实色背景，不使用 Material，否则 PDF 会出现灰块。

struct ReportDocumentView: View {
    let report: ScanReport

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            headerBlock

            ForEach(report.sections) { section in
                sectionBlock(section)
            }

            if let deep = report.deep {
                deepBlock(deep)
            }

            footerBlock
        }
        .padding(26)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(hex: 0x0B0618))
    }

    private var headerBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("iDevice X-Ray")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Spacer()
                Text("设备体检报告")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.5))
            }

            Text(report.deviceName)
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

            Text("\(report.identifier) · iOS \(report.osVersion) · \(report.mode.displayName)")
                .font(.system(size: 10))
                .foregroundStyle(Color.white.opacity(0.55))

            HStack(spacing: 16) {
                summaryItem("\(report.totalCount)", "检测项")
                summaryItem("\(report.readableCount)", "可读项")
                summaryItem("\(report.verifiedCount)", "已验证")
                summaryItem("\(report.completenessScore)%", "完整度")
            }
            .padding(.top, 6)

            Rectangle()
                .fill(Color.white.opacity(0.12))
                .frame(height: 1)
        }
    }

    private func summaryItem(_ value: String, _ title: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Text(title)
                .font(.system(size: 9))
                .foregroundStyle(Color.white.opacity(0.5))
        }
    }

    private func sectionBlock(_ section: ReportSection) -> some View {
        let accent = Color(hex: section.accentHex)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Circle()
                    .fill(accent)
                    .frame(width: 5, height: 5)
                Text(section.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(spacing: 0) {
                ForEach(section.fields) { field in
                    HStack(alignment: .top, spacing: 8) {
                        Text(field.title)
                            .font(.system(size: 10))
                            .foregroundStyle(Color.white.opacity(0.55))
                            .frame(width: 92, alignment: .leading)
                        Text(field.displayValue)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(field.confidence == .unavailable ? Color.white.opacity(0.3) : .white)
                        Spacer(minLength: 0)
                        Text(field.confidence.displayName)
                            .font(.system(size: 8))
                            .foregroundStyle(confidenceColor(field.confidence))
                    }
                    .padding(.vertical, 3)
                }
            }
            .padding(10)
            .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func deepBlock(_ deep: DeepScanResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("深度数据来源")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
            Text(deep.directDatabase == true
                 ? "\(deep.fileName) · 直接读取 Powerlog 数据库"
                 : "\(deep.fileName) · 扫描 \(deep.entriesScanned) 个条目 · 命中 \(deep.matchedFiles.count) 个文件")
                .font(.system(size: 9))
                .foregroundStyle(Color.white.opacity(0.5))
            ForEach(deep.warnings.prefix(3), id: \.self) { warning in
                Text("· \(warning)")
                    .font(.system(size: 9))
                    .foregroundStyle(Color(hex: 0xF59E0B))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var footerBlock: some View {
        VStack(alignment: .leading, spacing: 3) {
            Rectangle()
                .fill(Color.white.opacity(0.1))
                .frame(height: 1)
            Text("生成时间 \(Format.dateTime(report.createdAt)) · 机型库 \(DeviceCatalog.shared.version)")
                .font(.system(size: 8))
                .foregroundStyle(Color.white.opacity(0.4))
            Text("报告中的「不可读取」项代表本机确实无法获取该数据，未做任何估算填充。")
                .font(.system(size: 8))
                .foregroundStyle(Color.white.opacity(0.4))
        }
    }

    private func confidenceColor(_ confidence: Confidence) -> Color {
        switch confidence {
        case .verified: return Color(hex: 0x34D399)
        case .high: return Color(hex: 0x22D3EE)
        case .inferred: return Color(hex: 0xF59E0B)
        case .unavailable: return Color.white.opacity(0.3)
        }
    }
}

// MARK: - 分享卡片

struct ReportShareCard: View {
    let report: ScanReport

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("iDevice X-Ray")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Spacer()
                Text("设备体检报告")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.white.opacity(0.5))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(report.deviceName)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text("\(report.identifier) · iOS \(report.osVersion)")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.55))
            }

            HStack(spacing: 12) {
                scoreBadge
                VStack(alignment: .leading, spacing: 6) {
                    keyMetric("battery.level", "电量")
                    keyMetric("storage.usage", "存储使用率")
                    keyMetric("display.resolution", "分辨率")
                }
            }

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 4) {
                Text("\(report.readableCount)/\(report.totalCount) 项成功读取 · \(report.verifiedCount) 项已验证")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.white.opacity(0.55))
                Text("数据全部在本机处理，未上传任何服务器")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.white.opacity(0.35))
            }
        }
        .padding(24)
        .frame(width: 375, height: 500, alignment: .topLeading)
        .background(
            LinearGradient(
                colors: [Color(hex: 0x1A0B33), Color(hex: 0x0B0618)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    private var scoreBadge: some View {
        VStack(spacing: 2) {
            Text("\(report.completenessScore)")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Text("完整度")
                .font(.system(size: 9))
                .foregroundStyle(Color.white.opacity(0.5))
        }
        .frame(width: 92, height: 92)
        .background(Color(hex: 0x7C3AED).opacity(0.22), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color(hex: 0xA855F7).opacity(0.6), lineWidth: 1)
        }
    }

    private func keyMetric(_ key: String, _ fallback: String) -> some View {
        let field = report.allFields.first { $0.key == key }
        return HStack(spacing: 6) {
            Text(field?.title ?? fallback)
                .font(.system(size: 10))
                .foregroundStyle(Color.white.opacity(0.5))
            Text(field?.displayValue ?? "—")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
        }
    }
}
