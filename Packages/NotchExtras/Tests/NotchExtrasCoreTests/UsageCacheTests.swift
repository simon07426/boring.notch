import XCTest
@testable import NotchExtrasCore

final class UsageCacheTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "UsageCacheTests"

    override func setUp() {
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    func testSaveThenLoadRoundTrips() throws {
        let json = Data(#"{"five_hour":{"utilization":76,"resets_at":"2026-11-15T15:00:00Z"}}"#.utf8)
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        UsageCache.save(json, at: at, to: defaults)
        let loaded = try XCTUnwrap(UsageCache.load(from: defaults))
        XCTAssertEqual(loaded.snapshot.fiveHour?.percent, 76)
        XCTAssertEqual(loaded.updated, at)
    }

    func testLoadIsNilWhenEmptyOrCorrupt() {
        XCTAssertNil(UsageCache.load(from: defaults))
        UsageCache.save(Data("not json".utf8), at: Date(), to: defaults)
        XCTAssertNil(UsageCache.load(from: defaults))
    }

    func testAsOfText() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 2 * 86400 + 15 * 3600) // Sat 1970-01-03 15:00 UTC
        XCTAssertEqual(asOfText(now.addingTimeInterval(-20 * 60), now: now, calendar: cal), "as of 14:40")
        XCTAssertEqual(asOfText(now.addingTimeInterval(-20 * 3600), now: now, calendar: cal), "as of Fri 19:00")
    }
}
