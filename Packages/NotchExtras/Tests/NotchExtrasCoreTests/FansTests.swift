import XCTest
@testable import NotchExtrasCore

final class FansTests: XCTestCase {
    func testParseTyped() {
        let min = 2317.0, max = 6800.0
        XCTAssertNil(FanMath.parseTyped("", min: min, max: max))
        XCTAssertNil(FanMath.parseTyped("abc", min: min, max: max))
        XCTAssertEqual(FanMath.parseTyped("-5", min: min, max: max), 2317)
        XCTAssertEqual(FanMath.parseTyped("99999", min: min, max: max), 6800)
        XCTAssertEqual(FanMath.parseTyped("2350", min: min, max: max), 2350)
        XCTAssertEqual(FanMath.parseTyped(" 3000 ", min: min, max: max), 3000)
        XCTAssertEqual(FanMath.parseTyped("3000\n", min: min, max: max), 3000)
        XCTAssertNil(FanMath.parseTyped("30.5", min: min, max: max))
        XCTAssertNil(FanMath.parseTyped("+3000", min: min, max: max))
        XCTAssertNil(FanMath.parseTyped("3 000", min: min, max: max))
        XCTAssertNil(FanMath.parseTyped("-", min: min, max: max))
    }

    func testSnap() {
        let min = 2317.0, max = 6800.0
        XCTAssertEqual(FanMath.snap(2317, min: min, max: max), 2317)
        XCTAssertEqual(FanMath.snap(2360, min: min, max: max), 2400)
        XCTAssertEqual(FanMath.snap(6790, min: min, max: max), 6800)
        XCTAssertEqual(FanMath.snap(3049, min: min, max: max), 3000)
        XCTAssertEqual(FanMath.snap(2000, min: min, max: max), 2317)
        XCTAssertEqual(FanMath.snap(9000, min: min, max: max), 6800)
        XCTAssertEqual(FanMath.snap(2330, min: min, max: max), 2317)
    }

    func testDisplay() {
        XCTAssertEqual(FanMath.display(0), "Off")
        XCTAssertEqual(FanMath.display(0.4), "Off")
        XCTAssertEqual(FanMath.display(2990.4), "2990 rpm")
        XCTAssertEqual(FanMath.display(2990.6), "2991 rpm")
        XCTAssertEqual(FanMath.display(1e30), "99999 rpm")
        XCTAssertEqual(FanMath.display(.nan), "Off")
    }

    func testCommandParse() {
        XCTAssertEqual(FanCommand.parse("set 3000"), .set(3000))
        XCTAssertNil(FanCommand.parse("set"))
        XCTAssertNil(FanCommand.parse("set abc"))
        XCTAssertNil(FanCommand.parse("set 3000 4000"))
        XCTAssertNil(FanCommand.parse("reboot"))
        XCTAssertEqual(FanCommand.parse("status\n"), .status)
        XCTAssertEqual(FanCommand.parse("  auto  \n"), .auto)
        XCTAssertEqual(FanCommand.parse("ping"), .ping)
        XCTAssertNil(FanCommand.parse(""))
        XCTAssertNil(FanCommand.parse("set -5"))
        XCTAssertNil(FanCommand.parse("set +3000"))
        XCTAssertNil(FanCommand.parse("set 0"))
        XCTAssertNil(FanCommand.parse("set 99999999999999999999"))
        XCTAssertNil(FanCommand.parse("set 20001"))
        XCTAssertEqual(FanCommand.parse("set 20000"), .set(20000))
        XCTAssertEqual(FanCommand.parse("set 1"), .set(1))
    }

    func testWatchdog() {
        let base = Date(timeIntervalSinceReferenceDate: 1_000_000)
        var wd = FanWatchdog(timeout: 30)
        wd.touch(at: base)
        XCTAssertTrue(wd.shouldRevert(now: base.addingTimeInterval(31), manual: true))
        XCTAssertFalse(wd.shouldRevert(now: base.addingTimeInterval(29), manual: true))
        XCTAssertFalse(wd.shouldRevert(now: base.addingTimeInterval(31), manual: false))
    }

    func testWatchdogInitCountsAsTouch() {
        let wd = FanWatchdog(timeout: 30)
        XCTAssertFalse(wd.shouldRevert(now: Date().addingTimeInterval(29), manual: true))
        XCTAssertTrue(wd.shouldRevert(now: Date().addingTimeInterval(31), manual: true))
    }

    func testFloatEncoding() {
        XCTAssertEqual(SMCValue.encodeFloat(3000), [0x00, 0x80, 0x3B, 0x45])
        XCTAssertEqual(SMCValue.decodeFloat([0x00, 0x80, 0x3B, 0x45]), 3000)
        XCTAssertEqual(SMCValue.decodeFloat(SMCValue.encodeFloat(2317.5)), 2317.5)
    }

    func testFourCC() {
        XCTAssertEqual(SMCValue.fourCC("F0Md"), 0x4630_4D64)
    }

    func testFanStatusRoundTrip() throws {
        let status = FanStatus(fans: [FanInfo(index: 0, actual: 2990, min: 2317, max: 6800, target: 3000, manual: true)])
        let data = try JSONEncoder().encode(status)
        XCTAssertEqual(try JSONDecoder().decode(FanStatus.self, from: data), status)
    }

    func testReplies() {
        XCTAssertEqual(FanReply.ok, "{\"ok\":true}")
        XCTAssertEqual(FanReply.error("bad \"x\""), "{\"error\":\"bad \\\"x\\\"\"}")
    }
}
