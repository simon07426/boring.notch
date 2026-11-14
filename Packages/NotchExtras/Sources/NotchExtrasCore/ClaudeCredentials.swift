import Foundation

public enum UsageFetchError: String, Error {
    case noCredentials, keychainDenied, expired, network, badResponse
}

public struct ClaudeCredentials {
    public let accessToken: String
    public let expiresAt: Date?

    public init(accessToken: String, expiresAt: Date?) {
        self.accessToken = accessToken
        self.expiresAt = expiresAt
    }

    private struct Root: Decodable {
        struct OAuth: Decodable {
            let accessToken: String?
            let expiresAt: Double?
        }
        let claudeAiOauth: OAuth?
    }

    public static func parse(_ keychainData: Data) throws -> ClaudeCredentials {
        guard let root = try? JSONDecoder().decode(Root.self, from: keychainData),
              let token = root.claudeAiOauth?.accessToken, !token.isEmpty
        else { throw UsageFetchError.noCredentials }
        let expiry = root.claudeAiOauth?.expiresAt.map { Date(timeIntervalSince1970: $0 / 1000) }
        return ClaudeCredentials(accessToken: token, expiresAt: expiry)
    }

    /// Expired when the token expires within 60 s of `now`.
    public func isExpired(now: Date) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= now.addingTimeInterval(60)
    }
}
