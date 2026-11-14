import Foundation
import NotchExtrasCore

/// Installs / removes the root fan daemon (LaunchDaemon) with one administrator prompt.
/// Script building lives in NotchExtrasCore (`FanInstallScript`) so it is unit tested.
enum FanDaemonInstaller {
    static func isInstalled() -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: FanInstallScript.installedBinary) && fm.fileExists(atPath: FanInstallScript.installedPlist)
    }

    static func installScript(resourcesPath: String, uid: uid_t) -> Result<String, FanInstallScriptError> {
        FanInstallScript.build(resourcesPath: resourcesPath, uid: uid)
    }

    static func uninstallScript() -> String { FanInstallScript.uninstall() }

    /// Runs `script` as root via the standard administrator prompt. Must be called on the main thread.
    static func runPrivileged(_ script: String) -> (ok: Bool, message: String?) {
        let source = "do shell script \"\(FanInstallScript.appleScriptEscape(script))\" with administrator privileges"
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
