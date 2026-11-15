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
    /// `claude auth status` checks the login without a model call, so it costs no usage.
    public static let renewArguments = ["auth", "status"]

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
