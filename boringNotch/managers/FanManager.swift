import Combine
import Foundation
import NotchExtrasCore

/// Drives the Fans tab: polls the root fan daemon (through the XPC helper) while the tab is on
/// screen and keeps a heartbeat going while manual control is active.
@MainActor
final class FanManager: ObservableObject {
    static let shared = FanManager()

    @Published private(set) var status: FanStatus?
    @Published private(set) var sensors: SensorSummary?
    @Published private(set) var daemonInstalled = false
    /// The speed the user asked for. Shown instead of the polled target while set, because SMC
    /// readbacks lag a write by about a second.
    @Published private(set) var manualTarget: Double?
    /// Last daemon/installer problem, shown inline. Cleared by the next successful call.
    @Published private(set) var errorMessage: String?

    private let pollInterval: TimeInterval = 2
    private let heartbeatInterval: TimeInterval = 10
    private let debounce: TimeInterval = 0.3
    /// After this long, a status that reports no manual fan means the daemon reverted (sleep, watchdog).
    private let revertGrace: TimeInterval = 5

    private var pollTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var pendingSet: Task<Void, Never>?
    private var lastCommand: Task<Void, Never>?
    private var lastSetAt = Date.distantPast
    private var isInstalling = false
    private var installedMisses = 0
    /// Bumped by every setSpeed so a late `auto` reply can tell it was superseded.
    private var speedGeneration = 0
    /// Daemon client times out at 8 s; give up on a hung command just after.
    private static let commandTimeout: TimeInterval = 9

    private init() {}

    /// False only when the daemon reported no fans at all, which hides the tab.
    var hasFans: Bool { status?.fans.isEmpty != true }

    /// Common range across fans, nil without a status.
    var range: ClosedRange<Double>? {
        guard let fans = status?.fans, !fans.isEmpty else { return nil }
        let lo = fans.map(\.min).max() ?? 0
        let hi = fans.map(\.max).min() ?? 0
        return lo <= hi ? lo...hi : nil
    }

    /// What the slider and field show.
    var displayTarget: Double? {
        manualTarget ?? status?.fans.first?.target
    }

    // MARK: - Lifecycle

    /// The app always starts in Auto: send `auto` once if the daemon is installed.
    func startup() async {
        await refreshInstalled()
        guard daemonInstalled else { return }
        _ = await send("auto")
        await refreshStatus()
    }

    /// One transient "not installed" answer is ignored (manual state and heartbeat stay) unless
    /// `confirmed` (right after our own uninstall); a second consecutive one counts.
    func refreshInstalled(confirmed: Bool = false) async {
        if await XPCHelperClient.shared.isFanDaemonInstalled() {
            installedMisses = 0
            daemonInstalled = true
            return
        }
        installedMisses += 1
        if confirmed || installedMisses >= 2 || !daemonInstalled {
            daemonInstalled = false
            status = nil
            clearManual()
        }
    }

    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.poll()
                try? await Task.sleep(nanoseconds: UInt64(self.pollInterval * 1_000_000_000))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Commands

    func setSpeed(_ rpm: Double) {
        guard daemonInstalled, rpm.isFinite else { return }
        let target = rpm.rounded()
        speedGeneration += 1
        manualTarget = target
        lastSetAt = Date()
        startHeartbeat()
        pendingSet?.cancel()
        pendingSet = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(self.debounce * 1_000_000_000))
            guard !Task.isCancelled else { return }
            _ = await self.send("set \(Int(target))")
        }
    }

    func setAuto() {
        pendingSet?.cancel()
        pendingSet = nil
        Task { [weak self] in
            guard let self else { return }
            // Manual state and heartbeat stay until the daemon confirms; retry once on failure.
            let generation = self.speedGeneration
            var reply = await self.send("auto")
            if reply == nil, generation == self.speedGeneration { reply = await self.send("auto") }
            if reply != nil, generation == self.speedGeneration { self.clearManual() }
            // A status refresh would clear the error of a failed auto; keep it.
            let failure = reply == nil ? self.errorMessage : nil
            await self.refreshStatus()
            if let failure { self.errorMessage = failure }
        }
    }

    func installDaemon() async {
        guard !isInstalling else { return }
        isInstalling = true
        defer { isInstalling = false }
        switch await XPCHelperClient.shared.installFanDaemon() {
        case .success:
            errorMessage = nil
            await refreshInstalled()
            if daemonInstalled { await refreshStatus() }
        case .failure(let failure):
            errorMessage = failure.message
        }
    }

    func uninstallDaemon() async {
        guard !isInstalling else { return }
        isInstalling = true
        defer { isInstalling = false }
        pendingSet?.cancel()
        // Return fans to the system before the daemon goes away.
        if daemonInstalled { _ = await send("auto") }
        clearManual()
        switch await XPCHelperClient.shared.uninstallFanDaemon() {
        case .success:
            errorMessage = nil
            status = nil
            await refreshInstalled(confirmed: true)
        case .failure(let failure):
            errorMessage = failure.message
            await refreshInstalled()
        }
    }

    /// Best-effort `auto` for app termination; never waits longer than `timeout`.
    /// Skipped without a daemon. Waits for the in-flight command first so a pending `set`
    /// can't land after the `auto`. Spins the run loop instead of blocking, because the
    /// XPC client hops to the main actor.
    static func sendAutoBlocking(timeout: TimeInterval = 1) {
        let manager = FanManager.shared
        guard manager.daemonInstalled else { return }
        manager.pendingSet?.cancel()
        let inFlight = manager.lastCommand
        let done = DoneFlag()
        Task { @MainActor in
            await inFlight?.value
            _ = await XPCHelperClient.shared.fanCommand("auto")
            done.set()
        }
        let deadline = Date().addingTimeInterval(timeout)
        while !done.isSet, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    // MARK: - Internals

    private func poll() async {
        await refreshInstalled()
        if daemonInstalled { await refreshStatus() }
        let readings = await XPCHelperClient.shared.readSensors()
        if !readings.isEmpty { sensors = SensorMap.summarize(readings) }
    }

    private func refreshStatus() async {
        guard let reply = await send("status") else { return }
        guard let data = reply.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(FanStatus.self, from: data) else { return }
        status = decoded
        // The daemon went back to auto on its own (sleep, watchdog): stop showing a manual target.
        if manualTarget != nil,
           Date().timeIntervalSince(lastSetAt) > revertGrace,
           !decoded.fans.contains(where: \.manual) {
            clearManual()
        }
    }

    /// Sends one command, serialised behind earlier ones so `set` and `auto` never reorder.
    /// Returns the raw reply on success, nil on a nil reply or a daemon error (which is surfaced).
    private func send(_ line: String) async -> String? {
        let previous = lastCommand
        let task = Task { [weak self] () -> String? in
            await previous?.value
            guard self != nil else { return nil }
            return await Self.fanCommandWithTimeout(line, seconds: Self.commandTimeout)
        }
        lastCommand = Task { _ = await task.value }
        let reply = await task.value
        guard let reply else {
            errorMessage = "Fan daemon not responding"
            return nil
        }
        if let message = Self.errorText(in: reply) {
            errorMessage = message
            return nil
        }
        errorMessage = nil
        return reply
    }

    /// A hung daemon call must not stall the serial queue: resolve nil after `seconds`.
    private nonisolated static func fanCommandWithTimeout(_ line: String, seconds: TimeInterval) async -> String? {
        await withCheckedContinuation { continuation in
            let gate = ResumeOnce(continuation)
            let sleeper = Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                gate.resume(nil)
            }
            Task.detached {
                gate.resume(await XPCHelperClient.shared.fanCommand(line))
                sleeper.cancel()
            }
        }
    }

    private static func errorText(in reply: String) -> String? {
        struct Body: Decodable { let error: String }
        guard let data = reply.data(using: .utf8) else { return nil }
        return (try? JSONDecoder().decode(Body.self, from: data))?.error
    }

    private func clearManual() {
        manualTarget = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    /// Keeps the daemon's 30 s watchdog fed while manual, even with the notch closed.
    private func startHeartbeat() {
        guard heartbeatTask == nil else { return }
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                try? await Task.sleep(nanoseconds: UInt64(self.heartbeatInterval * 1_000_000_000))
                guard !Task.isCancelled, self.manualTarget != nil else { return }
                _ = await self.send("ping")
            }
        }
    }
}

private final class DoneFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String?, Never>?
    init(_ continuation: CheckedContinuation<String?, Never>) { self.continuation = continuation }
    func resume(_ value: String?) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(returning: value)
    }
}
