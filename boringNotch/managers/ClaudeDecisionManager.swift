import AppKit
import Combine
import Defaults
import Foundation
import NotchExtrasCore

extension Notification.Name {
    static let claudeDecisionArrived = Notification.Name("claudeDecisionArrived")
}

/// Holds the decision queue for the notch UI. The only consumer of `store.changes`.
@MainActor
final class ClaudeDecisionManager: ObservableObject {
    static let shared = ClaudeDecisionManager()

    let store = DecisionStore()

    @Published private(set) var current: PendingDecision?
    @Published private(set) var queuedCount: Int = 0
    @Published private(set) var lastDecisionAt: Date?

    private static let pendingLifetime: TimeInterval = 150
    private static let resolvedRetention: TimeInterval = 300
    private static let claudeDesktopBundleID = "com.anthropic.claudefordesktop"

    private var lastKnownIDs: [String] = []
    private var popupTracker = PopupTracker()
    private var changesTask: Task<Void, Never>?
    private var evictionTask: Task<Void, Never>?

    private init() {
        changesTask = Task { [weak self] in
            guard let self else { return }
            for await _ in self.store.changes {
                await self.refresh()
            }
        }
        evictionTask = Task { [store] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                await store.expirePending(olderThan: Self.pendingLifetime)
                await store.evictResolved(olderThan: Self.resolvedRetention)
            }
        }
    }

    // Actions are bound to the decision id the view rendered; a stale id is a no-op in the store.
    func allow(id: String) { resolve(id, .allow) }
    func deny(id: String) { resolve(id, .deny) }
    func answer(id: String, _ answers: [String: String]) { resolve(id, .answered(answers)) }

    /// Give the decision back to Claude's own prompt and bring Claude to the front.
    func handBack(id: String) {
        resolve(id, .withdrawn)
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.claudeDesktopBundleID).first {
            app.activate()
        }
    }

    private func resolve(_ id: String, _ status: DecisionStatus) {
        Task { await store.resolve(id, status) }
    }

    private func refresh() async {
        let pending = await store.pending
        let known = Set(lastKnownIDs)
        if pending.contains(where: { !known.contains($0.id) }) { lastDecisionAt = Date() }
        lastKnownIDs = pending.map(\.id)

        let next = pending.first
        current = next
        queuedCount = max(pending.count - 1, 0)

        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let allowed = PopupPolicy.shouldOpenNotch(
            frontmost: frontmost,
            popupEnabled: Defaults[.claudeDecisionPopup],
            showWhenFrontmost: Defaults[.claudePopupWhenFrontmost]
        )
        let shouldPost = popupTracker.shouldPost(current: next?.id, pending: pending.map(\.id), policyAllows: allowed)
        if shouldPost, let next {
            NotificationCenter.default.post(name: .claudeDecisionArrived, object: next.id)
        }
    }
}
