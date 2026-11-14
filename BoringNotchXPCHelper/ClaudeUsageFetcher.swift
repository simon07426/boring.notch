//
//  ClaudeUsageFetcher.swift
//  BoringNotchXPCHelper
//
//  Reads Claude Code's OAuth token from the Keychain and fetches usage JSON.
//  The token never leaves this process; only the usage JSON is returned.
//

import Foundation
import Security
import NotchExtrasCore

enum ClaudeUsageFetcher {
    private static let keychainService = "Claude Code-credentials"
    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    static func fetch() async -> Result<Data, UsageFetchError> {
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
            default: return .failure(.badResponse)
            }
        } catch {
            return .failure(.network)
        }
    }

    private static func readCredentials() -> Result<ClaudeCredentials, UsageFetchError> {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  let credentials = try? ClaudeCredentials.parse(data)
            else { return .failure(.noCredentials) }
            return .success(credentials)
        case errSecItemNotFound:
            return .failure(.noCredentials)
        case errSecAuthFailed, errSecUserCanceled, errSecInteractionNotAllowed:
            return .failure(.keychainDenied)
        default:
            return .failure(.noCredentials)
        }
    }
}
