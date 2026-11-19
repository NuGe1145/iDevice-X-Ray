import XCTest
@testable import iDeviceXRay

/// 机型库现在有两种条目：人工核对过规格的，和只知道名字与芯片的。
/// 后者大量字段为 null，解码必须成功 —— 否则整个机型库会退回「解析失败」。
final class DeviceCatalogDecodingTests: XCTestCase {

    private struct Payload: Decodable {
        let version: String
        let devices: [DeviceSpec]
    }

    func testDecodesEntryWithoutDetailedSpecs() throws {
        let json = """
        {
          "version": "2026.11",
          "devices": [
            {
              "identifier": "iPad13,16",
              "name": "iPad Air (5th generation) Wi-Fi",
              "family": "iPad",
              "chip": "M1",
              "ramGB": null,
              "screenInches": null,
              "nativeWidth": null,
              "nativeHeight": null,
              "ppi": null,
              "refreshRate": null,
              "panelType": null,
              "batteryDesignMah": null,
              "releaseYear": 2022,
              "modelNumbers": ["A2588"],
              "specSource": "name-only"
            }
          ]
        }
        """
        let payload = try JSONDecoder().decode(Payload.self, from: Data(json.utf8))
        let spec = try XCTUnwrap(payload.devices.first)

        XCTAssertEqual(spec.name, "iPad Air (5th generation) Wi-Fi")
        XCTAssertEqual(spec.chip, "M1")
        XCTAssertEqual(spec.releaseYear, 2022)
        XCTAssertEqual(spec.modelNumbers, ["A2588"])
        XCTAssertFalse(spec.hasDetailedSpecs)
        XCTAssertNil(spec.ppi)
    }

    func testDecodesCuratedEntry() throws {
        let json = """
        {
          "version": "2026.11",
          "devices": [
            {
              "identifier": "iPad13,16",
              "name": "iPad Air (5th generation) Wi-Fi",
              "family": "iPad",
              "chip": "M1",
              "ramGB": 8,
              "screenInches": 10.9,
              "nativeWidth": 2360,
              "nativeHeight": 1640,
              "ppi": 264,
              "refreshRate": 60,
              "panelType": "Liquid Retina (LCD)",
              "batteryDesignMah": 7606,
              "releaseYear": 2022,
              "specSource": "curated"
            }
          ]
        }
        """
        let payload = try JSONDecoder().decode(Payload.self, from: Data(json.utf8))
        let spec = try XCTUnwrap(payload.devices.first)

        XCTAssertTrue(spec.hasDetailedSpecs)
        XCTAssertEqual(spec.ppi, 264)
        XCTAssertEqual(spec.ramGB, 8)
    }
}
