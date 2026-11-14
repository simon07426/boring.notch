import XCTest
@testable import NotchExtrasCore

final class FanInstallScriptTests: XCTestCase {
    private let tricky = "/Applications/Boring Notch's.app/Contents/Resources"

    func testSpaceAndApostropheQuotedForShell() throws {
        let script = try FanInstallScript.build(resourcesPath: tricky, uid: 501, fileExists: { _ in true }).get()
        XCTAssertTrue(script.contains("'/Applications/Boring Notch'\\''s.app/Contents/Resources/theboringteam.boringnotch.fand'"))
        XCTAssertTrue(script.hasPrefix("set -e\n"))
        // The quoted script must survive the shell for real: parse it with sh -n.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-n", "-c", script]
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
    }

    func testAppleScriptEscapingOfBackslashAndQuote() {
        XCTAssertEqual(FanInstallScript.appleScriptEscape("a\\b\"c'd"), "a\\\\b\\\"c'd")
        let script = try! FanInstallScript.build(resourcesPath: tricky, uid: 1, fileExists: { _ in true }).get()
        // The shell's `'\''` becomes `'\\''` inside the AppleScript literal.
        XCTAssertTrue(FanInstallScript.appleScriptEscape(script).contains("Notch'\\\\''s.app"))
    }

    func testRejectsWrongResourcesSuffix() {
        for bad in ["/tmp/x", "/Applications/A.app/Contents/Resources/", "/Applications/A.app/Contents/Resources\n/Contents/Resources"] {
            XCTAssertEqual(FanInstallScript.build(resourcesPath: bad, uid: 1, fileExists: { _ in true }),
                           .failure(.init(message: "Unexpected resources path")), bad)
        }
    }

    func testRejectsMissingFiles() {
        XCTAssertEqual(FanInstallScript.build(resourcesPath: tricky, uid: 1, fileExists: { !$0.hasSuffix("fand") }),
                       .failure(.init(message: "Fan daemon binary missing from app bundle")))
        XCTAssertEqual(FanInstallScript.build(resourcesPath: tricky, uid: 1, fileExists: { !$0.hasSuffix(".plist") }),
                       .failure(.init(message: "Fan daemon plist missing from app bundle")))
    }

    func testUidSubstituted() throws {
        let script = try FanInstallScript.build(resourcesPath: tricky, uid: 1234, fileExists: { _ in true }).get()
        XCTAssertTrue(script.contains("s/__UID__/1234/"))
    }

    func testUninstallBootsOutAndRemovesBothFiles() {
        let s = FanInstallScript.uninstall()
        XCTAssertTrue(s.contains("bootout system/theboringteam.boringnotch.fand"))
        XCTAssertTrue(s.contains("/Library/LaunchDaemons/theboringteam.boringnotch.fand.plist"))
        XCTAssertTrue(s.contains("/Library/PrivilegedHelperTools/theboringteam.boringnotch.fand"))
    }
}
