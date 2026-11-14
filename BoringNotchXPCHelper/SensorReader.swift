import Foundation
import IOKit
import NotchExtrasCore

/// Reads temperature sensors: IOHID thermal services plus the SMC `Tg**` (GPU) keys.
/// Names are mapped to categories by `SensorMap` in NotchExtrasCore. Needs no root.
enum SensorReader {
    static func read() -> [SensorReading] {
        readIOHID() + readSMCGpu()
    }

    // MARK: - IOHID

    private typealias CreateFn = @convention(c) (CFAllocator?) -> Unmanaged<CFTypeRef>?
    private typealias SetMatchingFn = @convention(c) (CFTypeRef, CFDictionary) -> Int32
    private typealias CopyServicesFn = @convention(c) (CFTypeRef) -> Unmanaged<CFArray>?
    private typealias CopyPropertyFn = @convention(c) (CFTypeRef, CFString) -> Unmanaged<CFTypeRef>?
    private typealias CopyEventFn = @convention(c) (CFTypeRef, Int64, Int32, Int64) -> Unmanaged<CFTypeRef>?
    private typealias FloatValueFn = @convention(c) (CFTypeRef, Int32) -> Double

    private static let kIOHIDEventTypeTemperature: Int64 = 15

    private static func readIOHID() -> [SensorReading] {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY),
              let create = dlsym(handle, "IOHIDEventSystemClientCreate"),
              let setMatching = dlsym(handle, "IOHIDEventSystemClientSetMatching"),
              let copyServices = dlsym(handle, "IOHIDEventSystemClientCopyServices"),
              let copyProperty = dlsym(handle, "IOHIDServiceClientCopyProperty"),
              let copyEvent = dlsym(handle, "IOHIDServiceClientCopyEvent"),
              let floatValue = dlsym(handle, "IOHIDEventGetFloatValue")
        else { return [] }

        let createFn = unsafeBitCast(create, to: CreateFn.self)
        let setMatchingFn = unsafeBitCast(setMatching, to: SetMatchingFn.self)
        let copyServicesFn = unsafeBitCast(copyServices, to: CopyServicesFn.self)
        let copyPropertyFn = unsafeBitCast(copyProperty, to: CopyPropertyFn.self)
        let copyEventFn = unsafeBitCast(copyEvent, to: CopyEventFn.self)
        let floatValueFn = unsafeBitCast(floatValue, to: FloatValueFn.self)

        guard let client = createFn(kCFAllocatorDefault)?.takeRetainedValue() else { return [] }
        let matching = ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 0x0005] as CFDictionary
        _ = setMatchingFn(client, matching)
        guard let services = copyServicesFn(client)?.takeRetainedValue() as [AnyObject]? else { return [] }

        var readings: [SensorReading] = []
        for service in services {
            guard let name = copyPropertyFn(service, "Product" as CFString)?.takeRetainedValue() as? String,
                  let event = copyEventFn(service, kIOHIDEventTypeTemperature, 0, 0)?.takeRetainedValue()
            else { continue }
            let celsius = floatValueFn(event, Int32(kIOHIDEventTypeTemperature << 16))
            guard celsius.isFinite else { continue }
            readings.append(SensorReading(name: name, celsius: celsius))
        }
        return readings
    }

    // MARK: - SMC (GPU temperatures live in the `Tg**` keys on Apple Silicon)

    private struct Vers { var major: CChar = 0, minor: CChar = 0, build: CChar = 0, reserved: CChar = 0; var release: UInt16 = 0 }
    private struct PLimit { var version: UInt16 = 0, length: UInt16 = 0; var cpu: UInt32 = 0, gpu: UInt32 = 0, mem: UInt32 = 0 }
    // Explicit padding: Swift does not pad nested structs to their stride like C does.
    private struct KeyInfo { var dataSize: UInt32 = 0, dataType: UInt32 = 0; var attrs: CChar = 0; var pad: (UInt8, UInt8, UInt8) = (0, 0, 0) }
    /// Matches the 80-byte SMCKeyData_t used by AppleSMC.
    private struct SMCKeyData {
        var key: UInt32 = 0
        var vers = Vers()
        var pLimit = PLimit()
        var keyInfo = KeyInfo()
        var result: UInt8 = 0, status: UInt8 = 0, data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)
    }

    private static func fourCC(_ s: String) -> UInt32 { s.utf8.reduce(0) { $0 << 8 | UInt32($1) } }

    private static func fourCCString(_ v: UInt32) -> String {
        String(decoding: [UInt8(v >> 24), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)], as: UTF8.self)
    }

    private static func call(_ conn: io_connect_t, _ input: SMCKeyData) -> SMCKeyData? {
        var input = input
        var output = SMCKeyData()
        var size = MemoryLayout<SMCKeyData>.size
        let r = IOConnectCallStructMethod(conn, 2, &input, size, &output, &size)
        return (r == KERN_SUCCESS && output.result == 0) ? output : nil
    }

    private static func readSMCGpu() -> [SensorReading] {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return [] }
        defer { IOObjectRelease(service) }
        var conn: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &conn) == KERN_SUCCESS else { return [] }
        defer { IOServiceClose(conn) }

        func keyCount() -> Int {
            var info = SMCKeyData(); info.key = fourCC("#KEY"); info.data8 = 9
            guard let i = call(conn, info) else { return 0 }
            var read = SMCKeyData(); read.key = fourCC("#KEY"); read.keyInfo.dataSize = i.keyInfo.dataSize; read.data8 = 5
            guard let o = call(conn, read) else { return 0 }
            var bytes = o.bytes
            return withUnsafeBytes(of: &bytes) { b in Int(UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])) }
        }

        /// Reads a `flt ` key; nil when missing, wrong type, or not finite.
        func readFloat(_ key: UInt32) -> Double? {
            var info = SMCKeyData(); info.key = key; info.data8 = 9
            guard let i = call(conn, info), fourCCString(i.keyInfo.dataType) == "flt ", i.keyInfo.dataSize == 4 else { return nil }
            var read = SMCKeyData(); read.key = key; read.keyInfo.dataSize = i.keyInfo.dataSize; read.data8 = 5
            guard let o = call(conn, read) else { return nil }
            var bytes = o.bytes
            let value = Double(withUnsafeBytes(of: &bytes) { $0.loadUnaligned(as: Float.self) })
            return value.isFinite ? value : nil
        }

        func discoverGpuKeys() -> [UInt32] {
            var keys: [UInt32] = []
            for index in 0..<keyCount() {
                var byIndex = SMCKeyData(); byIndex.data8 = 8; byIndex.data32 = UInt32(index)
                guard let named = call(conn, byIndex), fourCCString(named.key).hasPrefix("Tg"),
                      readFloat(named.key) != nil else { continue }
                keys.append(named.key)
            }
            return keys
        }

        if gpuKeys.isEmpty { gpuKeys = discoverGpuKeys() }
        return gpuKeys.compactMap { key in
            readFloat(key).map { SensorReading(name: "SMC \(fourCCString(key))", celsius: $0) }
        }
    }

    /// `Tg**` flt keys, discovered once (enumerating ~2.4k SMC keys per poll is wasteful).
    /// Only touched from the helper's sensor reads; guarded by a lock.
    private static let gpuKeysLock = NSLock()
    private static var _gpuKeys: [UInt32] = []
    private static var gpuKeys: [UInt32] {
        get { gpuKeysLock.lock(); defer { gpuKeysLock.unlock() }; return _gpuKeys }
        set { gpuKeysLock.lock(); defer { gpuKeysLock.unlock() }; _gpuKeys = newValue }
    }
}
