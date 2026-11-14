import XCTest
@testable import NotchExtrasCore

final class ClaudeCredentialsTests: XCTestCase {
    func testParsesTokenAndExpiry() throws {
        let json = #"{"claudeAiOauth":{"accessToken":"tok","expiresAt":1731600000000}}"#
        let c = try ClaudeCredentials.parse(Data(json.utf8))
        XCTAssertEqual(c.accessToken, "tok")
        XCTAssertEqual(c.expiresAt, Date(timeIntervalSince1970: 1731600000))
    }

    func testExpiredWithin60s() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let soon = #"{"claudeAiOauth":{"accessToken":"t","expiresAt":1000030000}}"#
        let later = #"{"claudeAiOauth":{"accessToken":"t","expiresAt":1000120000}}"#
        XCTAssertTrue(try ClaudeCredentials.parse(Data(soon.utf8)).isExpired(now: now))
        XCTAssertFalse(try ClaudeCredentials.parse(Data(later.utf8)).isExpired(now: now))
    }

    func testMissingTokenThrows() {
        let json = #"{"claudeAiOauth":{}}"#
        XCTAssertThrowsError(try ClaudeCredentials.parse(Data(json.utf8)))
    }
}
