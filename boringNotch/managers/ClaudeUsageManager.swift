import Combine
import Foundation
import NotchExtrasCore

@MainActor
final class ClaudeUsageManager: ObservableObject {
    static let shared = ClaudeUsageManager()

    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var error: UsageFetchError?
    @Published private(set) var lastUpdated: Date?
    /// When a rate-limited refresh may be tried again.
    @Published private(set) var retryAt: Date?
    /// True while Claude Code's browser sign-in is open.
    @Published private(set) var isSigningIn = false
    /// Why the last sign-in attempt failed, if it did.
    @Published private(set) var signInError: String?

    private var timer: Timer?
    private var isRefreshing = false
    private let interval: TimeInterval = 300
    private var gate = UsageRefreshGate()

    private init() {
        if let cached = UsageCache.load() {
            snapshot = cached.snapshot
            lastUpdated = cached.updated
        }
    }

    func start() {
        guard timer == nil else { return }
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Opens Claude Code's sign-in in the browser, then refreshes once it completes.
    func signIn() async {
        guard !isSigningIn else { return }
        isSigningIn = true
        signInError = nil
        let failure = await XPCHelperClient.shared.signInToClaudeCode()
        isSigningIn = false
        signInError = failure
        if failure == nil { await refresh(manual: true) }
    }

    /// Keeps the last snapshot when a fetch fails. Automatic refreshes (timer, opening the tab)
    /// are skipped within a minute of the last call; every refresh waits out a rate-limit back-off.
    func refresh(manual: Bool = false) async {
        guard !isRefreshing, gate.shouldRefresh(now: Date(), manual: manual) else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        switch await XPCHelperClient.shared.fetchClaudeUsage() {
        case .success(let data):
            do {
                snapshot = try UsageSnapshot.parse(data)
                let now = Date()
                lastUpdated = now
                UsageCache.save(data, at: now)
                error = nil
                gate.recordSuccess()
                retryAt = nil
            } catch {
                self.error = .badResponse
            }
        case .failure(let failure):
            error = failure
            if failure == .rateLimited { gate.recordRateLimited(now: Date()) }
            retryAt = gate.retryAt
        }
    }
}
