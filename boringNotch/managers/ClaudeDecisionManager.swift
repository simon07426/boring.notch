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
                try? await Task.sleep(for: .seconds(60))
                await store.evictResolved(olderThan: Self.resolvedRetention)
            }
        }
    }

    func allow() { resolveCurrent(.allow) }
    func deny() { resolveCurrent(.deny) }
    func answer(_ answers: [String: String]) { resolveCurrent(.answered(answers)) }

    /// Give the decision back to Claude's own prompt and bring Claude to the front.
    func handBack() {
        resolveCurrent(.withdrawn)
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.claudeDesktopBundleID).first {
            app.activate()
        }
    }

    private func resolveCurrent(_ status: DecisionStatus) {
        guard let id = current?.id else { return }
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
