//
//  BoringNotchXPCHelperProtocol.swift
//  BoringNotchXPCHelper
//
//  Created by Alexander on 2025-11-16.
//

import Foundation

/// The protocol that this service will vend as its API. This protocol will also need to be visible to the process hosting the service.
@objc protocol BoringNotchXPCHelperProtocol {
    func isAccessibilityAuthorized(with reply: @escaping (Bool) -> Void)
    func requestAccessibilityAuthorization()
    func ensureAccessibilityAuthorization(_ promptIfNeeded: Bool, with reply: @escaping (Bool) -> Void)
    // Keyboard backlight / CoreBrightness access (performed by the helper)
    func isKeyboardBrightnessAvailable(with reply: @escaping (Bool) -> Void)
    func currentKeyboardBrightness(with reply: @escaping (NSNumber?) -> Void)
    func setKeyboardBrightness(_ value: Float, with reply: @escaping (Bool) -> Void)
    // Screen brightness access (performed by the helper)
    func isScreenBrightnessAvailable(with reply: @escaping (Bool) -> Void)
    func currentScreenBrightness(with reply: @escaping (NSNumber?) -> Void)
    func setScreenBrightness(_ value: Float, with reply: @escaping (Bool) -> Void)
    // Claude usage (token is read and used inside the helper only)
    func fetchClaudeUsage(with reply: @escaping (Data?, String?) -> Void)

    // Temperature sensors (JSON-encoded [SensorReading])
    func readSensors(with reply: @escaping (Data?) -> Void)

    // Root fan daemon (command line in, JSON reply line out)
    func fanCommand(_ line: String, with reply: @escaping (String?) -> Void)
    func isFanDaemonInstalled(with reply: @escaping (Bool) -> Void)
    func installFanDaemon(_ resourcesPath: String, with reply: @escaping (Bool, String?) -> Void)
    func uninstallFanDaemon(with reply: @escaping (Bool, String?) -> Void)

    func writeClaudeBridgeFile(_ json: Data, with reply: @escaping (Bool) -> Void)
    func removeClaudeBridgeFile(with reply: @escaping (Bool) -> Void)
}

