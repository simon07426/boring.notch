import Foundation

public actor DecisionStore {
    private struct Entry {
        let request: DecisionRequest
        var status: DecisionStatus = .pending
        var resolvedAt: Date?
    }

    private struct Waiter {
        let continuation: CheckedContinuation<DecisionStatus, Never>
        let timer: Task<Void, Never>
    }

    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    private var waiters: [String: [UUID: Waiter]] = [:]

    /// Yields once per add / resolve / remove.
    public nonisolated let changes: AsyncStream<Void>
    private let changeContinuation: AsyncStream<Void>.Continuation

    public init() {
        var c: AsyncStream<Void>.Continuation!
        changes = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { c = $0 }
        changeContinuation = c
    }

    deinit { changeContinuation.finish() }

    public var pending: [PendingDecision] {
        order.compactMap { id in
            guard let e = entries[id], e.status == .pending else { return nil }
            return PendingDecision(id: id, request: e.request)
        }
    }

    @discardableResult
    public func add(_ r: DecisionRequest) -> String {
        let id = UUID().uuidString.lowercased()
        entries[id] = Entry(request: r)
        order.append(id)
        changeContinuation.yield()
        return id
    }

    /// First answer wins: resolving an already-resolved or unknown decision is a no-op.
    public func resolve(_ id: String, _ s: DecisionStatus) {
        guard s != .pending, entries[id]?.status == .pending else { return }
        entries[id]?.status = s
        entries[id]?.resolvedAt = Date()
        wake(id, with: s)
        changeContinuation.yield()
    }

    /// The asker withdrew the decision; it disappears and reads as `.gone` from now on.
    public func remove(_ id: String) {
        guard entries.removeValue(forKey: id) != nil else { return }
        order.removeAll { $0 == id }
        wake(id, with: .gone)
        changeContinuation.yield()
    }

    /// Drops resolved decisions that were resolved more than `olderThan` seconds before `now`.
    public func evictResolved(olderThan age: TimeInterval, now: Date = Date()) {
        let stale = entries.filter { _, e in
            guard let at = e.resolvedAt else { return false }
            return now.timeIntervalSince(at) > age
        }.keys
        guard !stale.isEmpty else { return }
        for id in stale { entries[id] = nil }
        let gone = Set(stale)
        order.removeAll { gone.contains($0) }
    }

    public func status(_ id: String) -> DecisionStatus {
        entries[id]?.status ?? .gone
    }

    public func wait(_ id: String, timeout: Duration) async -> DecisionStatus {
        let current = status(id)
        if current != .pending || timeout <= .zero { return current }

        let token = UUID()
        return await withCheckedContinuation { cont in
            let timer = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                await self?.expire(id, token)
            }
            waiters[id, default: [:]][token] = Waiter(continuation: cont, timer: timer)
        }
    }

    private func expire(_ id: String, _ token: UUID) {
        guard let w = waiters[id]?.removeValue(forKey: token) else { return }
        if waiters[id]?.isEmpty == true { waiters[id] = nil }
        w.continuation.resume(returning: status(id))
    }

    private func wake(_ id: String, with s: DecisionStatus) {
        guard let ws = waiters.removeValue(forKey: id) else { return }
        for w in ws.values {
            w.timer.cancel()
            w.continuation.resume(returning: s)
        }
    }
}
