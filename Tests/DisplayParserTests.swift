import XCTest
@testable import iDeviceXRay

/// 面板供应商是这次唯一从 sysdiagnose 里新解出来的字段。
/// 这里固定住两件事：前缀映射不瞎猜、序列号只保留三位。
final class DisplayParserTests: XCTestCase {

    func testVendorPrefixMapping() {
        XCTAssertEqual(DisplayLogParser.vendorName(for: "G9NABC1234"), "三星显示")
        XCTAssertEqual(DisplayLogParser.vendorName(for: "G9PXYZ"), "三星显示")
        XCTAssertEqual(DisplayLogParser.vendorName(for: "G9Q001"), "三星显示")
        XCTAssertEqual(DisplayLogParser.vendorName(for: "GVC7H2"), "LG Display")
        XCTAssertEqual(DisplayLogParser.vendorName(for: "GH3ABCD"), "LG Display")
        XCTAssertEqual(DisplayLogParser.vendorName(for: "C3F1234"), "京东方")
        XCTAssertEqual(DisplayLogParser.vendorName(for: "C61234"), "京东方")
    }

    func testUnknownCodeIsNotGuessed() {
        XCTAssertNil(DisplayLogParser.vendorName(for: "ZZZ999"))
        XCTAssertNil(DisplayLogParser.vendorName(for: "G8N123"))
        XCTAssertNil(DisplayLogParser.vendorName(for: "AB"))
    }

    func testParsesPanelSerialFromDeviceTree() {
        let text = """
            | |   "raw-panel-serial-number" = <"G9NABCDEF1234">
            | |   "display-panel-id" = 12
        """

        var outcome = DeepParser.Outcome()
        DisplayLogParser.parse(text: text, fileName: "IODeviceTree", into: &outcome)

        XCTAssertEqual(outcome.values["display.vendor"], "三星显示")
        XCTAssertEqual(outcome.values["display.panelCode"], "G9N•••")
        // 完整序列号不得出现在结果里
        XCTAssertFalse(outcome.values.values.contains { $0.contains("ABCDEF1234") })
    }

    func testUnlistedCodeIsReportedAsIs() {
        let text = #""raw-panel-serial-number" = <"X7Q0001">"#

        var outcome = DeepParser.Outcome()
        DisplayLogParser.parse(text: text, fileName: "IODeviceTree", into: &outcome)

        XCTAssertEqual(outcome.values["display.vendor"], "未收录（代码 X7Q）")
        XCTAssertEqual(outcome.values["display.panelCode"], "X7Q•••")
    }

    func testFallsBackToComponentIDs() {
        let text = """
            "DisplayVendorID" = 1552
            "ProductID" = 4104
        """

        var outcome = DeepParser.Outcome()
        DisplayLogParser.parse(text: text, fileName: "ioreg", into: &outcome)

        XCTAssertNil(outcome.values["display.vendor"])
        XCTAssertEqual(outcome.values["display.panelCode"], "Vendor 1552 · Product 4104")
    }
}
