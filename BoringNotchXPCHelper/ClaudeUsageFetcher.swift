//
//  ClaudeUsageFetcher.swift
//  BoringNotchXPCHelper
//
//  Reads Claude Code's OAuth token from the Keychain and fetches usage JSON.
//  The token never leaves this process; only the usage JSON is returned.
//

import Foundation
import NotchExtrasCore

enum ClaudeUsageFetcher {
    private static let keychainService = "Claude Code-credentials"
    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    private static let renewalLock = NSLock()
    nonisolated(unsafe) private static var renewalThrottle = RenewalThrottle()

    /// On an expired login, asks Claude Code to renew it (at most every 10 minutes) and retries once.
    static func fetch() async -> Result<Data, UsageFetchError> {
        let first = await attempt()
        guard case .failure(.expired) = first, takeRenewalSlot(), askClaudeCodeToRenew() else { return first }
        return await attempt()
    }

    private static func takeRenewalSlot() -> Bool {
        renewalLock.lock()
        defer { renewalLock.unlock() }
        return renewalThrottle.shouldAttempt(now: Date())
    }

    /// Runs `claude auth status`. Claude Code renews and stores its own login while checking it;
    /// this process never writes the credentials. Returns true when the CLI ran successfully.
    private static func askClaudeCodeToRenew() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard let cli = ClaudeCLI.locate(home: home),
              let outcome = ProcessRunner.run(cli, arguments: ClaudeCLI.renewArguments, timeout: 20)
        else { return false }
        return !outcome.timedOut && outcome.status == 0
    }

    private static func attempt() async -> Result<Data, UsageFetchError> {
        let credentials: ClaudeCredentials
        switch readCredentials() {
        case .success(let c): credentials = c
        case .failure(let e): return .failure(e)
        }
        if credentials.isExpired(now: Date()) { return .failure(.expired) }

        var request = URLRequest(url: usageURL, timeoutInterval: 15)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failure(.badResponse) }
            switch http.statusCode {
            case 200: return .success(data)
            case 401: return .failure(.expired)
            case 429: return .failure(.rateLimited)
            default: return .failure(.badResponse)
            }
        } catch {
            return .failure(.network)
        }
    }

    /// Reads the token through `/usr/bin/security`: Claude Code's item trusts that tool, and an XPC
    /// service cannot present the Keychain access prompt itself. Read-only; the output is never logged.
    private static func readCredentials() -> Result<ClaudeCredentials, UsageFetchError> {
        guard let outcome = ProcessRunner.run(
            "/usr/bin/security",
            arguments: ["find-generic-password", "-s", keychainService, "-w"],
            timeout: 5
        ) else { return .failure(.keychainDenied) }
        if outcome.timedOut { return .failure(.keychainDenied) }
        switch outcome.status {
        case 0: break
        case 44: return .failure(.noCredentials)
        default: return .failure(.keychainDenied)
        }
        var bytes = outcome.stdout
        while let last = bytes.last, last == 0x0A || last == 0x0D { bytes.removeLast() }
        guard let credentials = try? ClaudeCredentials.parse(bytes) else { return .failure(.noCredentials) }
        return .success(credentials)
    }
}
