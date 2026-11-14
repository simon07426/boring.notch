import Combine
import Foundation
import NotchExtrasCore

@MainActor
final class ClaudeUsageManager: ObservableObject {
    static let shared = ClaudeUsageManager()

    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var error: UsageFetchError?
    @Published private(set) var lastUpdated: Date?

    private var timer: Timer?
    private var isRefreshing = false
    private let interval: TimeInterval = 120

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

    /// Keeps the last snapshot when a fetch fails.
    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        switch await XPCHelperClient.shared.fetchClaudeUsage() {
        case .success(let data):
            do {
                snapshot = try UsageSnapshot.parse(data)
                lastUpdated = Date()
                error = nil
            } catch {
                self.error = .badResponse
            }
        case .failure(let failure):
            error = failure
        }
    }
}
