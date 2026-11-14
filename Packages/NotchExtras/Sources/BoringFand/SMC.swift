import Foundation
import IOKit
import NotchExtrasCore

/// Minimal AppleSMC client for the fan daemon. Only the calls the daemon needs:
/// read key info, read bytes, write bytes. Uses the 80-byte `SMCKeyData_t` layout
/// (struct method selector 2; data8 = 9 key info, 5 read bytes, 6 write bytes).
final class SMC {
    private struct Vers { var major: CChar = 0, minor: CChar = 0, build: CChar = 0, reserved: CChar = 0; var release: UInt16 = 0 }
    private struct PLimit { var version: UInt16 = 0, length: UInt16 = 0; var cpu: UInt32 = 0, gpu: UInt32 = 0, mem: UInt32 = 0 }
    // Explicit padding: Swift does not pad nested structs to their stride like C does.
    private struct KeyInfo { var dataSize: UInt32 = 0, dataType: UInt32 = 0; var attrs: CChar = 0; var pad: (UInt8, UInt8, UInt8) = (0, 0, 0) }
    private struct KeyData {
        var key: UInt32 = 0
        var vers = Vers()
        var pLimit = PLimit()
        var keyInfo = KeyInfo()
        var result: UInt8 = 0, status: UInt8 = 0, data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)
    }

    struct KeyInfoResult {
        let size: Int
        let type: UInt32
    }

    private var conn: io_connect_t = 0

    init?() {
        guard MemoryLayout<KeyData>.size == 80 else { return nil }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &conn) == KERN_SUCCESS else { return nil }
    }

    deinit { IOServiceClose(conn) }

    /// Returns nil on a kernel error; the caller distinguishes SMC result codes via `result`.
    private func call(_ input: KeyData) -> KeyData? {
        var input = input
        var output = KeyData()
        var size = MemoryLayout<KeyData>.size
        let r = IOConnectCallStructMethod(conn, 2, &input, size, &output, &size)
        return r == KERN_SUCCESS ? output : nil
    }

    func info(_ key: String) -> KeyInfoResult? {
        var input = KeyData(); input.key = SMCValue.fourCC(key); input.data8 = 9
        guard let out = call(input), out.result == 0 else { return nil }
        return KeyInfoResult(size: Int(out.keyInfo.dataSize), type: out.keyInfo.dataType)
    }

    func read(_ key: String) -> (info: KeyInfoResult, bytes: [UInt8])? {
        guard let ki = info(key), ki.size > 0, ki.size <= 32 else { return nil }
        var input = KeyData(); input.key = SMCValue.fourCC(key)
        input.keyInfo.dataSize = UInt32(ki.size); input.data8 = 5
        guard var out = call(input), out.result == 0 else { return nil }
        let bytes = withUnsafeBytes(of: &out.bytes) { Array($0.prefix(ki.size)) }
        return (ki, bytes)
    }

    /// Writes `bytes` (must match the key's size). Returns nil on success, otherwise a message.
    func write(_ key: String, _ bytes: [UInt8]) -> String? {
        guard !bytes.isEmpty, bytes.count <= 32 else { return "bad size" }
        var input = KeyData(); input.key = SMCValue.fourCC(key)
        input.keyInfo.dataSize = UInt32(bytes.count); input.data8 = 6
        withUnsafeMutableBytes(of: &input.bytes) { dst in
            for (i, b) in bytes.enumerated() { dst[i] = b }
        }
        guard let out = call(input) else { return "\(key): kernel call failed" }
        return out.result == 0 ? nil : "\(key): smc result \(out.result)"
    }

    // MARK: - Typed helpers

    func readFloat(_ key: String) -> Double? {
        guard let r = read(key), r.info.size == 4 else { return nil }
        let v = SMCValue.decodeFloat(r.bytes)
        return v.isFinite ? Double(v) : nil
    }

    func readByte(_ key: String) -> UInt8? {
        guard let r = read(key), r.info.size == 1 else { return nil }
        return r.bytes[0]
    }

    func writeFloat(_ key: String, _ value: Double) -> String? {
        write(key, SMCValue.encodeFloat(Float(value)))
    }

    func writeByte(_ key: String, _ value: UInt8) -> String? {
        write(key, [value])
    }
}
