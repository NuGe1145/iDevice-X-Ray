import Foundation

/// 从诊断档案的文本里抽取字段。
/// 解析策略是「宽进严出」：宁可解不出来，也不猜数值。
enum DeepParser {

    struct Outcome {
        var values: [String: String] = [:]
        var notes: [String] = []
    }

    static let interestingKeywords = [
        "battery", "powerlog", "power", "ioreg", "iokit",
        "display", "iomfb", "backlight", "applearmio", "device tree"
    ]

    static func parse(files: [(name: String, data: Data)]) -> Outcome {
        var outcome = Outcome()

        for file in files {
            let slice = file.data.prefix(2_000_000)
            guard !slice.isEmpty else { continue }
            let text = String(decoding: slice, as: UTF8.self)

            BatteryLogParser.parse(text: text, fileName: file.name, into: &outcome)
            DisplayLogParser.parse(text: text, fileName: file.name, into: &outcome)
        }

        return outcome
    }
}

// MARK: - 电池

enum BatteryLogParser {

    private static let cycleRegexes = make([
        #"cycle[_\s]?count["\s:=]{1,8}(\d+)"#,
        #""CycleCount"\s*=\s*(\d+)"#
    ])

    private static let designCapacityRegexes = make([
        #"design[_\s]?capacity["\s:=]{1,8}(\d+)"#,
        #""DesignCapacity"\s*=\s*(\d+)"#
    ])

    private static let maxCapacityRegexes = make([
        #"(?:apple)?raw[_\s]?max[_\s]?capacity["\s:=]{1,8}(\d+)"#,
        #"nominal[_\s]?charge[_\s]?capacity["\s:=]{1,8}(\d+)"#,
        #""AppleRawMaxCapacity"\s*=\s*(\d+)"#
    ])

    private static let temperatureRegexes = make([
        #""Temperature"\s*=\s*(\d+)"#,
        #"battery[_\s]?temperature["\s:=]{1,8}(\d+)"#
    ])

    private static let voltageRegexes = make([
        #""Voltage"\s*=\s*(\d+)"#,
        #"battery[_\s]?voltage["\s:=]{1,8}(\d+)"#
    ])

    static func parse(text: String, fileName: String, into outcome: inout DeepParser.Outcome) {
        let cycle = firstInt(cycleRegexes, in: text)
        let design = firstInt(designCapacityRegexes, in: text)
        let maxCapacity = firstInt(maxCapacityRegexes, in: text)
        let temperature = firstInt(temperatureRegexes, in: text)
        let voltage = firstInt(voltageRegexes, in: text)

        if let cycle, cycle > 0, cycle < 5000 {
            outcome.values["battery.cycleCount"] = "\(cycle) 次"
        }

        if let design, design > 100, design < 20_000 {
            outcome.values["battery.designCapacity"] = "\(design) mAh"
        }

        if let maxCapacity, let design, design > 0, maxCapacity > 0 {
            let percent = Double(maxCapacity) / Double(design) * 100
            if percent > 30, percent <= 125 {
                outcome.values["battery.health"] = String(format: "%.0f%%", percent)
            }
        }

        if let temperature {
            if let celsius = toCelsius(temperature) {
                outcome.values["battery.temperature"] = String(format: "%.1f °C", celsius)
            }
        }

        if let voltage {
            let volts = voltage > 100 ? Double(voltage) / 1000.0 : Double(voltage)
            if volts > 2.0, volts < 6.0 {
                outcome.values["battery.voltage"] = String(format: "%.2f V", volts)
            }
        }

        if outcome.values.isEmpty {
            outcome.notes.append("\(fileName)：未匹配到电池字段")
        }
    }

    /// AppleSmartBattery 的温度通常以 0.1K 为单位，个别版本是 0.1°C
    private static func toCelsius(_ raw: Int) -> Double? {
        let asKelvin = Double(raw) / 10.0 - 273.15
        if asKelvin > -30, asKelvin < 100 { return asKelvin }

        let asCelsius = Double(raw) / 10.0
        if asCelsius > -30, asCelsius < 100 { return asCelsius }

        return nil
    }

    private static func make(_ patterns: [String]) -> [NSRegularExpression] {
        patterns.compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
    }

    private static func firstInt(_ regexes: [NSRegularExpression], in text: String) -> Int? {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for regex in regexes {
            if let match = regex.firstMatch(in: text, options: [], range: range),
               match.numberOfRanges > 1,
               let captured = Range(match.range(at: 1), in: text),
               let value = Int(text[captured]) {
                return value
            }
        }
        return nil
    }
}

// MARK: - 显示

enum DisplayLogParser {

    private static let vendorRegexes = make([
        #"display[_\s]?vendor[_\s]?id["\s:=]{1,8}(0x[0-9a-fA-F]+|\d+)"#,
        #""DisplayVendorID"\s*=\s*(\d+)"#
    ])

    private static let productRegexes = make([
        #"display[_\s]?product[_\s]?id["\s:=]{1,8}(0x[0-9a-fA-F]+|\d+)"#,
        #""ProductID"\s*=\s*(\d+)"#
    ])

    static func parse(text: String, fileName: String, into outcome: inout DeepParser.Outcome) {
        let vendor = firstString(vendorRegexes, in: text)
        let product = firstString(productRegexes, in: text)

        guard vendor != nil || product != nil else { return }

        var parts: [String] = []
        if let vendor { parts.append("Vendor \(vendor)") }
        if let product { parts.append("Product \(product)") }

        outcome.values["display.panelCode"] = parts.joined(separator: " · ")
        outcome.notes.append("\(fileName)：取到显示组件 ID，但厂商名无法由 ID 可靠映射，未做推断")
    }

    private static func make(_ patterns: [String]) -> [NSRegularExpression] {
        patterns.compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
    }

    private static func firstString(_ regexes: [NSRegularExpression], in text: String) -> String? {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for regex in regexes {
            if let match = regex.firstMatch(in: text, options: [], range: range),
               match.numberOfRanges > 1,
               let captured = Range(match.range(at: 1), in: text) {
                return String(text[captured])
            }
        }
        return nil
    }
}
