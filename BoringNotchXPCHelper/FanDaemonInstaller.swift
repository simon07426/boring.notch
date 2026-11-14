import Foundation

/// Installs / removes the root fan daemon (LaunchDaemon) with one administrator prompt.
enum FanDaemonInstaller {
    static let label = "theboringteam.boringnotch.fand"
    static let installedBinary = "/Library/PrivilegedHelperTools/\(label)"
    static let installedPlist = "/Library/LaunchDaemons/\(label).plist"

    static func isInstalled() -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: installedBinary) && fm.fileExists(atPath: installedPlist)
    }

    /// Single-quotes `s` for /bin/sh.
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Escapes `s` for use inside an AppleScript double-quoted string literal.
    static func appleScriptEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Shell script (unescaped) that installs the daemon. `resourcesPath` is the app's Resources directory.
    static func installScript(resourcesPath: String, uid: uid_t, fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Result<String, FanInstallScriptError> {
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

    static func uninstallScript() -> String {
        [
            "set -e",
            "/bin/launchctl bootout system/\(label) 2>/dev/null || true",
            "/bin/rm -f \(shellQuote(installedPlist)) \(shellQuote(installedBinary))",
        ].joined(separator: "\n")
    }

    /// Runs `script` as root via the standard administrator prompt. Must be called on the main thread.
    static func runPrivileged(_ script: String) -> (ok: Bool, message: String?) {
        let source = "do shell script \"\(appleScriptEscape(script))\" with administrator privileges"
        guard let apple = NSAppleScript(source: source) else { return (false, "Could not build installer script") }
        var errorInfo: NSDictionary?
        apple.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let msg = errorInfo[NSAppleScript.errorMessage] as? String ?? "Installation failed"
            return (false, msg)
        }
        return (true, nil)
    }
}

struct FanInstallScriptError: Error {
    let message: String
}
