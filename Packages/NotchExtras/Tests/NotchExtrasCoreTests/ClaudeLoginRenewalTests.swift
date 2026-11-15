import XCTest
@testable import NotchExtrasCore

final class ClaudeLoginRenewalTests: XCTestCase {
    func testThrottleAllowsFirstAttemptThenWaitsTenMinutes() {
        var throttle = RenewalThrottle()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(throttle.shouldAttempt(now: t0))
        XCTAssertFalse(throttle.shouldAttempt(now: t0.addingTimeInterval(60)))
        XCTAssertFalse(throttle.shouldAttempt(now: t0.addingTimeInterval(599)))
        XCTAssertTrue(throttle.shouldAttempt(now: t0.addingTimeInterval(600)))
        XCTAssertFalse(throttle.shouldAttempt(now: t0.addingTimeInterval(601)))
    }

    func testCandidatePathsPreferUserInstall() {
        XCTAssertEqual(ClaudeCLI.candidates(home: "/Users/a"), [
            "/Users/a/.local/bin/claude",
            "/Users/a/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ])
    }

    func testLocatePicksFirstExecutable() {
        let found = ClaudeCLI.locate(home: "/Users/a") { $0 == "/opt/homebrew/bin/claude" || $0 == "/usr/local/bin/claude" }
        XCTAssertEqual(found, "/opt/homebrew/bin/claude")
        XCTAssertNil(ClaudeCLI.locate(home: "/Users/a") { _ in false })
    }

    func testRenewArgumentsUseNoModelCall() {
        XCTAssertEqual(ClaudeCLI.renewArguments, ["auth", "status"])
    }
}
