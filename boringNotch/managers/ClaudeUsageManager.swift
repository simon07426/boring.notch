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

    private var timer: Timer?
    private var isRefreshing = false
    private let interval: TimeInterval = 300
    private var gate = UsageRefreshGate()

    private init() {}

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
                lastUpdated = Date()
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
