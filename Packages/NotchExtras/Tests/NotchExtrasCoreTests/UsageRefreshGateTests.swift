import XCTest
@testable import NotchExtrasCore

final class UsageRefreshGateTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testAutomaticRefreshWaitsOneMinuteManualDoesNot() {
        var gate = UsageRefreshGate()
        XCTAssertTrue(gate.shouldRefresh(now: t0, manual: false))
        XCTAssertFalse(gate.shouldRefresh(now: t0.addingTimeInterval(30), manual: false))
        XCTAssertTrue(gate.shouldRefresh(now: t0.addingTimeInterval(31), manual: true))
        XCTAssertFalse(gate.shouldRefresh(now: t0.addingTimeInterval(60), manual: false))
        XCTAssertTrue(gate.shouldRefresh(now: t0.addingTimeInterval(91), manual: false))
    }

    func testRateLimitBacksOffAndDoubles() {
        var gate = UsageRefreshGate()
        XCTAssertTrue(gate.shouldRefresh(now: t0, manual: false))
        gate.recordRateLimited(now: t0)
        XCTAssertEqual(gate.retryAt, t0.addingTimeInterval(120))
        XCTAssertFalse(gate.shouldRefresh(now: t0.addingTimeInterval(119), manual: true))
        XCTAssertTrue(gate.shouldRefresh(now: t0.addingTimeInterval(120), manual: false))
        gate.recordRateLimited(now: t0.addingTimeInterval(120))
        XCTAssertEqual(gate.retryAt, t0.addingTimeInterval(120 + 240))
    }

    func testBackoffCapsAtThirtyMinutesAndSuccessResets() {
        var gate = UsageRefreshGate()
        for _ in 0..<10 { gate.recordRateLimited(now: t0) }
        XCTAssertEqual(gate.retryAt, t0.addingTimeInterval(1800))
        gate.recordSuccess()
        XCTAssertNil(gate.retryAt)
        gate.recordRateLimited(now: t0)
        XCTAssertEqual(gate.retryAt, t0.addingTimeInterval(120))
    }

    func testRateLimitedErrorRoundTripsOverXPC() {
        XCTAssertEqual(UsageFetchError(rawValue: UsageFetchError.rateLimited.rawValue), .rateLimited)
    }
}
