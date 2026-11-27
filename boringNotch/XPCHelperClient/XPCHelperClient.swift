import Foundation
import Cocoa
import AsyncXPCConnection
import NotchExtrasCore

final class XPCHelperClient: NSObject {
    nonisolated static let shared = XPCHelperClient()
    
    private let serviceName = "theboringteam.boringnotch.BoringNotchXPCHelper"
    
    private var remoteService: RemoteXPCService<BoringNotchXPCHelperProtocol>?
    private var connection: NSXPCConnection?
    private var lastKnownAuthorization: Bool?
    private var monitoringTask: Task<Void, Never>?
    
    deinit {
        connection?.invalidate()
        stopMonitoringAccessibilityAuthorization()
    }
    
    // MARK: - Connection Management (Main Actor Isolated)
    
    @MainActor
    private func ensureRemoteService() -> RemoteXPCService<BoringNotchXPCHelperProtocol> {
        if let existing = remoteService {
            return existing
        }
        
        let conn = NSXPCConnection(serviceName: serviceName)
        
        conn.interruptionHandler = { [weak self] in
            Task { @MainActor in
                self?.connection = nil
                self?.remoteService = nil
            }
        }
        
        conn.invalidationHandler = { [weak self] in
            Task { @MainActor in
                self?.connection = nil
                self?.remoteService = nil
            }
        }
        
        conn.resume()
        
        let service = RemoteXPCService<BoringNotchXPCHelperProtocol>(
            connection: conn,
            remoteInterface: BoringNotchXPCHelperProtocol.self
        )
        
        connection = conn
        remoteService = service
        return service
    }
    
    @MainActor
    private func getRemoteService() -> RemoteXPCService<BoringNotchXPCHelperProtocol>? {
        remoteService
    }
    
    @MainActor
    private func notifyAuthorizationChange(_ granted: Bool) {
        guard lastKnownAuthorization != granted else { return }
        lastKnownAuthorization = granted
        NotificationCenter.default.post(
            name: .accessibilityAuthorizationChanged,
            object: nil,
            userInfo: ["granted": granted]
        )
    }

    // MARK: - Monitoring
    nonisolated func startMonitoringAccessibilityAuthorization(every interval: TimeInterval = 3.0) {
        // Ensure only one monitor exists
        stopMonitoringAccessibilityAuthorization()
        monitoringTask = Task.detached { [weak self] in
            guard let self = self else { return }
            while !Task.isCancelled {
                // Call the helper method periodically which will notify on change
                _ = await self.isAccessibilityAuthorized()
                do {
                    try await Task.sleep(for: .seconds(interval))
                } catch { break }
            }
        }
    }

    nonisolated func stopMonitoringAccessibilityAuthorization() {
        monitoringTask?.cancel()
        monitoringTask = nil
    }

    // Expose whether the client is actively monitoring (useful for tests/debug)
    var isMonitoring: Bool {
        return monitoringTask != nil
    }
    
    // MARK: - Accessibility
    
    nonisolated func requestAccessibilityAuthorization() {
        Task {
            let service = await MainActor.run {
                ensureRemoteService()
            }
            try? await service.withService { service in
                service.requestAccessibilityAuthorization()
            }
        }
    }
    
    nonisolated func isAccessibilityAuthorized() async -> Bool {
        do {
            let service = await MainActor.run {
                ensureRemoteService()
            }
            let result: Bool = try await service.withContinuation { service, continuation in
                service.isAccessibilityAuthorized { authorized in
                    continuation.resume(returning: authorized)
                }
            }
            await MainActor.run {
                notifyAuthorizationChange(result)
            }
            return result
        } catch {
            return false
        }
    }
    
    nonisolated func ensureAccessibilityAuthorization(promptIfNeeded: Bool) async -> Bool {
        do {
            let service = await MainActor.run {
                ensureRemoteService()
            }
            let result: Bool = try await service.withContinuation { service, continuation in
                service.ensureAccessibilityAuthorization(promptIfNeeded) { authorized in
                    continuation.resume(returning: authorized)
                }
            }
            await MainActor.run {
                notifyAuthorizationChange(result)
            }
            return result
        } catch {
            return false
        }
    }
    
    // MARK: - Keyboard Brightness
    
    nonisolated func isKeyboardBrightnessAvailable() async -> Bool {
        do {
            let service = await MainActor.run {
                ensureRemoteService()
            }
            return try await service.withContinuation { service, continuation in
                service.isKeyboardBrightnessAvailable { available in
                    continuation.resume(returning: available)
                }
            }
        } catch {
            return false
        }
    }
    
    nonisolated func currentKeyboardBrightness() async -> Float? {
        do {
            let service = await MainActor.run {
                ensureRemoteService()
            }
            let result: NSNumber? = try await service.withContinuation { service, continuation in
                service.currentKeyboardBrightness { value in
                    continuation.resume(returning: value)
                }
            }
            return result?.floatValue
        } catch {
            return nil
        }
    }
    
    nonisolated func setKeyboardBrightness(_ value: Float) async -> Bool {
        do {
            let service = await MainActor.run {
                ensureRemoteService()
            }
            return try await service.withContinuation { service, continuation in
                service.setKeyboardBrightness(value) { success in
                    continuation.resume(returning: success)
                }
            }
        } catch {
            return false
        }
    }
    
    // MARK: - Screen Brightness
    
    nonisolated func isScreenBrightnessAvailable() async -> Bool {
        do {
            let service = await MainActor.run {
                ensureRemoteService()
            }
            return try await service.withContinuation { service, continuation in
                service.isScreenBrightnessAvailable { available in
                    continuation.resume(returning: available)
                }
            }
        } catch {
            return false
        }
    }
    
    nonisolated func currentScreenBrightness() async -> Float? {
        do {
            let service = await MainActor.run {
                ensureRemoteService()
            }
            let result: NSNumber? = try await service.withContinuation { service, continuation in
                service.currentScreenBrightness { value in
                    continuation.resume(returning: value)
                }
            }
            return result?.floatValue
        } catch {
            return nil
        }
    }
    
    nonisolated func setScreenBrightness(_ value: Float) async -> Bool {
        do {
            let service = await MainActor.run {
                ensureRemoteService()
            }
            return try await service.withContinuation { service, continuation in
                service.setScreenBrightness(value) { success in
                    continuation.resume(returning: success)
                }
            }
        } catch {
            return false
        }
    }

    nonisolated func fetchClaudeUsage() async -> Result<Data, UsageFetchError> {
        do {
            let service = await MainActor.run {
                ensureRemoteService()
            }
            let result: Result<Data, UsageFetchError> = try await service.withContinuation { service, continuation in
                service.fetchClaudeUsage { data, errorCode in
                    if let data {
                        continuation.resume(returning: .success(data))
                    } else {
                        continuation.resume(returning: .failure(errorCode.flatMap(UsageFetchError.init(rawValue:)) ?? .badResponse))
                    }
                }
            }
            return result
        } catch {
            return .failure(.network)
        }
    }

    /// Nil on success, otherwise a short message for the user.
    nonisolated func signInToClaudeCode() async -> String? {
        do {
            let service = await MainActor.run {
                ensureRemoteService()
            }
            return try await service.withContinuation { service, continuation in
                service.signInToClaudeCode { ok, message in
                    continuation.resume(returning: ok ? nil : (message ?? "Sign-in didn't finish"))
                }
            }
        } catch {
            return "Couldn't reach the helper"
        }
    }

    nonisolated func readSensors() async -> [SensorReading] {
        do {
            let service = await MainActor.run {
                ensureRemoteService()
            }
            let data: Data? = try await service.withContinuation { service, continuation in
                service.readSensors { data in
                    continuation.resume(returning: data)
                }
            }
            guard let data else { return [] }
            return (try? JSONDecoder().decode([SensorReading].self, from: data)) ?? []
        } catch {
            return []
        }
    }

    // MARK: - Fan daemon

    nonisolated func fanCommand(_ line: String) async -> String? {
        do {
            let service = await MainActor.run {
                ensureRemoteService()
            }
            return try await service.withContinuation { service, continuation in
                service.fanCommand(line) { reply in
                    continuation.resume(returning: reply)
                }
            }
        } catch {
            return nil
        }
    }

    nonisolated func isFanDaemonInstalled() async -> Bool {
        do {
            let service = await MainActor.run {
                ensureRemoteService()
            }
            return try await service.withContinuation { service, continuation in
                service.isFanDaemonInstalled { installed in
                    continuation.resume(returning: installed)
                }
            }
        } catch {
            return false
        }
    }

    nonisolated func installFanDaemon() async -> Result<Void, FanInstallError> {
        guard let resources = Bundle.main.resourcePath else {
            return .failure(FanInstallError(message: "App resources not found"))
        }
        return await runFanInstall { service, done in service.installFanDaemon(resources, with: done) }
    }

    nonisolated func uninstallFanDaemon() async -> Result<Void, FanInstallError> {
        await runFanInstall { service, done in service.uninstallFanDaemon(with: done) }
    }

    private nonisolated func runFanInstall(
        _ call: @escaping (BoringNotchXPCHelperProtocol, @escaping (Bool, String?) -> Void) -> Void
    ) async -> Result<Void, FanInstallError> {
        do {
            let service = await MainActor.run {
                ensureRemoteService()
            }
            return try await service.withContinuation { service, continuation in
                call(service) { ok, message in
                    continuation.resume(returning: ok ? .success(()) : .failure(FanInstallError(message: message ?? "Operation failed")))
                }
            }
        } catch {
            return .failure(FanInstallError(message: "Helper unavailable"))
        }
    }

    nonisolated func writeClaudeBridgeFile(_ json: Data) async -> Bool {
        do {
            let service = await MainActor.run {
                ensureRemoteService()
            }
            return try await service.withContinuation { service, continuation in
                service.writeClaudeBridgeFile(json) { ok in
                    continuation.resume(returning: ok)
                }
            }
        } catch {
            return false
        }
    }

    nonisolated func removeClaudeBridgeFile() async -> Bool {
        do {
            let service = await MainActor.run {
                ensureRemoteService()
            }
            return try await service.withContinuation { service, continuation in
                service.removeClaudeBridgeFile { ok in
                    continuation.resume(returning: ok)
                }
            }
        } catch {
            return false
        }
    }
}

extension Notification.Name {
    static let accessibilityAuthorizationChanged = Notification.Name("accessibilityAuthorizationChanged")
}



struct FanInstallError: Error {
    let message: String
}
