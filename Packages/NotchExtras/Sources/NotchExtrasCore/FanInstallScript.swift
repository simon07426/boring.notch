import Foundation

public struct FanInstallScriptError: Error, Equatable {
    public let message: String
}

/// Pure builders for the root fan daemon install/uninstall shell scripts (security-relevant quoting).
public enum FanInstallScript {
    public static let label = "theboringteam.boringnotch.fand"
    public static let installedBinary = "/Library/PrivilegedHelperTools/\(label)"
    public static let installedPlist = "/Library/LaunchDaemons/\(label).plist"

    /// Single-quotes `s` for /bin/sh.
    public static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Escapes `s` for use inside an AppleScript double-quoted string literal.
    public static func appleScriptEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// `resourcesPath` is the app's Resources directory.
    public static func build(resourcesPath: String, uid: UInt32,
                             fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Result<String, FanInstallScriptError> {
        guard resourcesPath.hasSuffix("/Contents/Resources"), !resourcesPath.contains("\n") else {
            return .failure(.init(message: "Unexpected resources path"))
        }
        let srcBinary = resourcesPath + "/\(label)"
        let srcPlist = resourcesPath + "/\(label).plist"
        guard fileExists(srcBinary) else { return .failure(.init(message: "Fan daemon binary missing from app bundle")) }
        guard fileExists(srcPlist) else { return .failure(.init(message: "Fan daemon plist missing from app bundle")) }

        let bin = shellQuote(installedBinary)
        let plist = shellQuote(installedPlist)
        let lines = [
            "set -e",
            // Reinstall: unload a running daemon first (ignore "not loaded").
            "/bin/launchctl bootout system/\(label) 2>/dev/null || true",
            "/bin/mkdir -p /Library/PrivilegedHelperTools",
            "/usr/bin/install -m 0755 -o root -g wheel \(shellQuote(srcBinary)) \(bin)",
            "/usr/bin/sed 's/__UID__/\(uid)/' \(shellQuote(srcPlist)) > \(plist)",
            "/usr/sbin/chown root:wheel \(plist)",
            "/bin/chmod 0644 \(plist)",
            "/bin/launchctl bootstrap system \(plist)",
        ]
        return .success(lines.joined(separator: "\n"))
    }

    public static func uninstall() -> String {
        [
            "set -e",
            "/bin/launchctl bootout system/\(label) 2>/dev/null || true",
            "/bin/rm -f \(shellQuote(installedPlist)) \(shellQuote(installedBinary))",
        ].joined(separator: "\n")
    }
}
