import Foundation

/// Limits how often Boring Notch asks Claude Code to renew its login.
public struct RenewalThrottle {
    public let minInterval: TimeInterval
    private var lastAttempt: Date?

    public init(minInterval: TimeInterval = 600) {
        self.minInterval = minInterval
    }

    /// True (and records the attempt) when no attempt happened within `minInterval`.
    public mutating func shouldAttempt(now: Date) -> Bool {
        if let lastAttempt, now.timeIntervalSince(lastAttempt) < minInterval { return false }
        lastAttempt = now
        return true
    }
}

/// Finds the Claude Code CLI. Boring Notch never renews the login itself: it runs Claude Code,
/// which renews and stores its own login, then reads the Keychain again.
public enum ClaudeCLI {
    /// A one-word Haiku request: Claude Code only renews an expired login when it makes a real
    /// request (`claude auth status` does not). No tools, no saved session, and only project
    /// settings, so the user's own hooks (TV bridge, notch decisions) do not run. Run it from an
    /// empty directory so no project settings apply either.
    public static let renewArguments = [
        "-p", "Reply with: ok",
        "--model", "haiku",
        "--setting-sources", "project",
        "--no-session-persistence",
        "--tools", "",
    ]

    public static func candidates(home: String) -> [String] {
        [
            home + "/.local/bin/claude",
            home + "/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
    }

    public static func locate(home: String,
                              isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> String? {
        candidates(home: home).first(where: isExecutable)
    }
}
