import XCTest
@testable import NotchExtrasCore

final class ClaudeUsageTests: XCTestCase {
    func testParsesBuckets() throws {
        let json = #"{"five_hour":{"utilization":46.0,"resets_at":"2026-11-14T15:00:00.123+00:00"},"seven_day":{"utilization":27,"resets_at":"2026-11-19T09:00:00+00:00"},"seven_day_opus":null,"extra":1}"#
        let s = try UsageSnapshot.parse(Data(json.utf8))
        XCTAssertEqual(s.fiveHour?.percent, 46)
        XCTAssertEqual(s.weekly?.percent, 27)
        XCTAssertNotNil(s.fiveHour?.resetsAt)
        XCTAssertNotNil(s.weekly?.resetsAt)
        XCTAssertNil(s.weeklyModelBucket)
    }

    func testNullBucketsHiddenAndPercentClamped() throws {
        let s = try UsageSnapshot.parse(Data(#"{"five_hour":{"utilization":130,"resets_at":null},"seven_day":null}"#.utf8))
        XCTAssertEqual(s.fiveHour?.percent, 100)
        XCTAssertNil(s.fiveHour?.resetsAt)
        XCTAssertNil(s.weekly)
    }

    func testModelBucket() throws {
        let s = try UsageSnapshot.parse(Data(#"{"seven_day_opus":{"utilization":5,"resets_at":null}}"#.utf8))
        XCTAssertEqual(s.weeklyModelName, "Opus")
        XCTAssertEqual(s.weeklyModelBucket?.percent, 5)
    }

    func testOAuthAppsBucketIgnored() throws {
        let s = try UsageSnapshot.parse(Data(#"{"seven_day_oauth_apps":{"utilization":9,"resets_at":null}}"#.utf8))
        XCTAssertNil(s.weeklyModelBucket)
        XCTAssertNil(s.weeklyModelName)
    }

    func testGarbageThrows() {
        XCTAssertThrowsError(try UsageSnapshot.parse(Data("nope".utf8)))
    }

    func testLevels() {
        XCTAssertEqual(UsageLevel.of(70), .normal)
        XCTAssertEqual(UsageLevel.of(70.1), .warning)
        XCTAssertEqual(UsageLevel.of(90), .warning)
        XCTAssertEqual(UsageLevel.of(90.1), .critical)
    }

    func testResetText() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 0) // Thu 1970-01-01 00:00 UTC
        XCTAssertEqual(resetText(now.addingTimeInterval(2*3600 + 14*60), now: now, calendar: cal), "resets in 2h 14m")
        XCTAssertEqual(resetText(now.addingTimeInterval(40*60), now: now, calendar: cal), "resets in 40m")
        XCTAssertEqual(resetText(now.addingTimeInterval(5*86400 + 9*3600), now: now, calendar: cal), "resets Tue 09:00")
        XCTAssertEqual(resetText(nil, now: now, calendar: cal), "")
        XCTAssertEqual(resetText(now, now: now, calendar: cal), "reset")
        XCTAssertEqual(resetText(now.addingTimeInterval(-3600), now: now, calendar: cal), "reset")
    }

    func testPercentAfterReset() {
        let now = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(UsageBucket(percent: 75, resetsAt: now.addingTimeInterval(-1)).percent(at: now), 0)
        XCTAssertEqual(UsageBucket(percent: 75, resetsAt: now.addingTimeInterval(60)).percent(at: now), 75)
        XCTAssertEqual(UsageBucket(percent: 75, resetsAt: nil).percent(at: now), 75)
    }

    func testUpdatedAgoText() {
        let now = Date(timeIntervalSince1970: 100_000)
        XCTAssertEqual(updatedAgoText(now.addingTimeInterval(-30), now: now), "just now")
        XCTAssertEqual(updatedAgoText(now.addingTimeInterval(-59 * 60), now: now), "59m ago")
        XCTAssertEqual(updatedAgoText(now.addingTimeInterval(-889 * 60), now: now), "14h ago")
        XCTAssertEqual(updatedAgoText(now.addingTimeInterval(-50 * 3600), now: now), "2d ago")
    }
}
