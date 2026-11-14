import XCTest
@testable import NotchExtrasCore

final class SensorsTests: XCTestCase {
    private func r(_ n: String, _ c: Double) -> SensorReading { SensorReading(name: n, celsius: c) }

    func testCpuIsMaxOfDieSensors() {
        let s = SensorMap.summarize([r("PMU tdie1", 44.5), r("PMU tdie10", 45.03), r("PMU tdie2", 44.06)])
        XCTAssertEqual(s.cpu, 45.03)
    }

    func testGpuMapped() {
        let s = SensorMap.summarize([r("SMC Tg0W", 48.7), r("SMC Tg1l", 55.19), r("SMC Tg0e", 48.8)])
        XCTAssertEqual(s.gpu, 55.19)
        XCTAssertNil(s.cpu)
    }

    func testExtrasOrderAndLabels() {
        let s = SensorMap.summarize([
            r("zzz sensor", 30), r("gas gauge battery", 32.3), r("PMU tdev1", 41.58), r("PMU tdev2", 43.75),
            r("PMU tcal", 51.85), r("NAND CH0 temp", 35), r("Trackpad Temp", 29), r("aaa sensor", 28),
            r("PMU tdie0", 44), r("PMU TP1g", 44.9),
        ])
        XCTAssertEqual(s.extras.map(\.name), ["SSD", "Trackpad", "Power manager", "Battery", "aaa sensor", "zzz sensor"])
        XCTAssertEqual(s.extras.map(\.celsius), [35, 29, 44.9, 32.3, 28, 30])
    }

    func testOutOfRangeDropped() {
        let s = SensorMap.summarize([r("PMU tdie1", 0), r("PMU tdie2", 130), r("PMU tdie3", -5), r("NAND CH0 temp", 129.9), r("gas gauge battery", 200)])
        XCTAssertNil(s.cpu)
        XCTAssertEqual(s.extras, [r("SSD", 129.9)])
    }

    func testMissingCategoriesHidden() {
        let s = SensorMap.summarize([r("PMU tdie1", 44)])
        XCTAssertEqual(s.cpu, 44)
        XCTAssertNil(s.gpu)
        XCTAssertTrue(s.extras.isEmpty)
    }

    func testDuplicateUnrecognisedNamesCollapseToMax() {
        let s = SensorMap.summarize([r("mystery", 30), r("mystery", 33)])
        XCTAssertEqual(s.extras, [r("mystery", 33)])
    }
}
