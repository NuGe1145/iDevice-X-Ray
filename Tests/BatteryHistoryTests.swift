import XCTest
@testable import iDeviceXRay

/// 本机历史：不依赖 sysdiagnose 的那条路。
/// 这里验证的都是纯计算与落盘行为，不需要真机传感器。
@MainActor
final class BatteryHistoryTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("history-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: 构造

    private func sample(
        id: Int,
        time: Date,
        level: Double?,
        state: ChargeSample.ChargeState,
        current: Double? = nil,
        batteryTemperature: Double? = nil
    ) -> ChargeSample {
        ChargeSample(
            id: id,
            time: time,
            inputVoltage: nil,
            inputCurrent: nil,
            inputWatts: nil,
            batteryVoltage: 3.85,
            batteryCurrent: current,
            batteryWatts: current.map { abs($0) * 3.85 },
            batteryTemperature: batteryTemperature,
            chargerTemperature: nil,
            socTemperature: nil,
            level: level,
            state: state,
            adapterName: nil,
            adapterRatedWatts: nil
        )
    }

    // MARK: 日聚合

    func testDailyAggregation() {
        let store = BatteryHistoryStore(directory: directory)
        let base = Date()

        store.ingest(sample(id: 1, time: base, level: 0.42, state: .charging,
                            current: 2.0, batteryTemperature: 31.5), dt: 10)
        store.ingest(sample(id: 2, time: base.addingTimeInterval(10), level: 0.55, state: .charging,
                            current: 2.0, batteryTemperature: 35.0), dt: 10)

        XCTAssertEqual(store.recordedDayCount, 1)
        let record = try? XCTUnwrap(store.records.first)
        XCTAssertEqual(record?.sampleCount, 2)
        XCTAssertEqual(record?.levelMin ?? 0, 0.42, accuracy: 0.001)
        XCTAssertEqual(record?.levelMax ?? 0, 0.55, accuracy: 0.001)
        XCTAssertEqual(record?.batteryTempMax ?? 0, 35.0, accuracy: 0.001)
        XCTAssertEqual(record?.chargingSeconds ?? 0, 20, accuracy: 0.001)
        XCTAssertEqual(record?.plugEvents, 1)
    }

    func testUnpluggedDoesNotCountAsChargingTime() {
        let store = BatteryHistoryStore(directory: directory)
        let base = Date()

        store.ingest(sample(id: 1, time: base, level: 0.6, state: .unplugged), dt: 30)
        store.ingest(sample(id: 2, time: base.addingTimeInterval(30), level: 0.6, state: .unplugged), dt: 30)

        XCTAssertEqual(store.records.first?.chargingSeconds ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(store.records.first?.pluggedSeconds ?? -1, 0, accuracy: 0.001)
    }

    // MARK: 容量估算

    func testCapacityEstimateFromChargingSegment() {
        let store = BatteryHistoryStore(directory: directory)
        let base = Date()

        // 2.0 A 充 30 秒 ≈ 16.7 mAh；每步 +1% 电量，共 20 步 +20%
        var time = base
        var level = 0.50
        for index in 0..<20 {
            store.ingest(sample(id: index, time: time, level: level, state: .charging, current: 2.0), dt: 30)
            time = time.addingTimeInterval(30)
            level += 0.01
        }
        // 拔线结算
        store.ingest(sample(id: 99, time: time, level: level, state: .unplugged), dt: 5)

        let estimate = try? XCTUnwrap(store.capacityEstimate)
        // 20 × 16.67 mAh = 333.3 mAh，除以 20% ≈ 1667 mAh
        XCTAssertEqual(estimate?.milliampereHours ?? 0, 1667, accuracy: 40)
        XCTAssertEqual(estimate?.sampleCount, 1)
    }

    func testShortSegmentIsRejected() {
        let store = BatteryHistoryStore(directory: directory)
        let base = Date()

        // 只涨了 5%，误差太大，不该产出容量
        store.ingest(sample(id: 1, time: base, level: 0.50, state: .charging, current: 2.0), dt: 60)
        store.ingest(sample(id: 2, time: base.addingTimeInterval(60), level: 0.55, state: .charging, current: 2.0), dt: 60)
        store.ingest(sample(id: 3, time: base.addingTimeInterval(120), level: 0.55, state: .plugged), dt: 5)

        XCTAssertNil(store.capacityEstimate)
    }

    func testSamplingGapDiscardsSegment() {
        let store = BatteryHistoryStore(directory: directory)
        let base = Date()

        store.ingest(sample(id: 1, time: base, level: 0.50, state: .charging, current: 2.0), dt: 60)
        // 中间断档 10 分钟：这段时间充进去的电没被积分，片段必须作废
        store.ingest(sample(id: 2, time: base.addingTimeInterval(600), level: 0.75, state: .charging, current: 2.0), dt: 60)
        store.ingest(sample(id: 3, time: base.addingTimeInterval(660), level: 0.75, state: .unplugged), dt: 5)

        XCTAssertNil(store.capacityEstimate)
    }

    func testHealthPercentUsesMedianObservation() {
        let store = BatteryHistoryStore(directory: directory)
        let base = Date()

        let record = CapacityObservation(id: UUID(), time: base, milliampHours: 800, deltaLevel: 0.40)
        XCTAssertEqual(record.capacityMah, 2000, accuracy: 0.01)

        XCTAssertNil(store.healthPercent(designMah: 3000))
    }

    func testMedian() {
        XCTAssertEqual(BatteryHistoryStore.median([3, 1, 2]), 2, accuracy: 0.001)
        XCTAssertEqual(BatteryHistoryStore.median([4, 1, 3, 2]), 2.5, accuracy: 0.001)
        XCTAssertEqual(BatteryHistoryStore.median([7]), 7, accuracy: 0.001)
        XCTAssertEqual(BatteryHistoryStore.median([]), 0, accuracy: 0.001)
    }

    // MARK: 落盘

    func testPersistenceRoundTrip() {
        let store = BatteryHistoryStore(directory: directory)
        let base = Date()

        store.ingest(sample(id: 1, time: base, level: 0.3, state: .charging,
                            current: 1.5, batteryTemperature: 30), dt: 30)
        store.flush()

        let reloaded = BatteryHistoryStore(directory: directory)
        XCTAssertEqual(reloaded.recordedDayCount, 1)
        XCTAssertEqual(reloaded.records.first?.sampleCount, 1)
        XCTAssertEqual(reloaded.records.first?.batteryTempMax ?? 0, 30, accuracy: 0.001)
    }

    func testResetClearsFile() {
        let store = BatteryHistoryStore(directory: directory)
        store.ingest(sample(id: 1, time: Date(), level: 0.5, state: .charging, current: 1.0), dt: 30)
        store.flush()
        store.reset()

        XCTAssertEqual(store.recordedDayCount, 0)
        XCTAssertNil(store.capacityEstimate)
        XCTAssertEqual(BatteryHistoryStore(directory: directory).recordedDayCount, 0)
    }
}
