import Foundation

public enum PopupPolicy {
    /// Frontmost apps where the user is already looking at Claude, so the notch stays closed.
    public static let suppressingBundleIDs: Set<String> = [
        "com.anthropic.claudefordesktop",
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable",
        "com.microsoft.VSCode",
        "com.todesktop.230313mzl4w4u92", // Cursor
    ]

    public static func shouldOpenNotch(frontmost: String?, popupEnabled: Bool, showWhenFrontmost: Bool) -> Bool {
        guard popupEnabled else { return false }
        if showWhenFrontmost { return true }
        guard let frontmost else { return true }
        return !suppressingBundleIDs.contains(frontmost)
    }
}

/// Decides, per queue change, whether the notch should pop for the current decision.
/// Each decision id is considered once; ids no longer pending are forgotten.
public struct PopupTracker: Sendable {
    private var handled = Set<String>()

    public init() {}

    public mutating func shouldPost(current: String?, pending: [String], policyAllows: Bool) -> Bool {
        handled.formIntersection(pending)
        guard let current, !handled.contains(current) else { return false }
        handled.insert(current)
        return policyAllows
    }
}
