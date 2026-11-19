import Foundation
import Observation

/// 报告本地存档。全部写在 App 沙盒内，不上传任何服务器。
@Observable
final class ReportStore {

    static let shared = ReportStore()

    private(set) var reports: [ScanReport] = []

    private let fileURL: URL
    private let maxCount = 100

    init() {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        fileURL = directory.appendingPathComponent("reports.json")
        load()
    }

    func add(_ report: ScanReport) {
        reports.insert(report, at: 0)
        if reports.count > maxCount {
            reports = Array(reports.prefix(maxCount))
        }
        save()
    }

    func delete(_ report: ScanReport) {
        reports.removeAll { $0.id == report.id }
        save()
    }

    func clear() {
        reports = []
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        reports = (try? decoder.decode([ScanReport].self, from: data)) ?? []
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(reports) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
