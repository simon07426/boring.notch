import Foundation

// Pure fan-control logic shared by the root fan daemon and the Fans tab UI.
// No IO here: SMC access lives in the daemon, rendering lives in the app.

public struct FanInfo: Codable, Equatable {
    public let index: Int
    public let actual: Double
    public let min: Double
    public let max: Double
    public let target: Double
    public let manual: Bool

    public init(index: Int, actual: Double, min: Double, max: Double, target: Double, manual: Bool) {
        self.index = index
        self.actual = actual
        self.min = min
        self.max = max
        self.target = target
        self.manual = manual
    }
}

public struct FanStatus: Codable, Equatable {
    public let fans: [FanInfo]

    public init(fans: [FanInfo]) {
        self.fans = fans
    }
}

public enum FanMath {
    /// Nearest multiple of `step`, clamped to [min, max]. Range ends are returned exactly.
    public static func snap(_ v: Double, min: Double, max: Double, step: Double = 100) -> Double {
        guard v.isFinite else { return min }
        if v <= min { return min }
        if v >= max { return max }
        let snapped = (v / step).rounded() * step
        return Swift.min(Swift.max(snapped, min), max)
    }

    /// Accepts an optional leading "-" followed by ASCII digits (surrounding whitespace is ignored).
    /// Any other input is nil. Integers outside the range are clamped to [min, max].
    public static func parseTyped(_ s: String, min: Double, max: Double) -> Double? {
        var body = Substring(s.trimmingCharacters(in: .whitespacesAndNewlines))
        let negative = body.hasPrefix("-")
        if negative { body = body.dropFirst() }
        guard !body.isEmpty, body.allSatisfy({ $0 >= "0" && $0 <= "9" }), let magnitude = Double(body) else {
            return nil
        }
        let value = negative ? -magnitude : magnitude
        return Swift.min(Swift.max(value, min), max)
    }

    /// Below 1 RPM (or not a finite reading) the fan is shown as off.
    public static func display(_ rpm: Double) -> String {
        guard rpm.isFinite, rpm >= 1 else { return "Off" }
        return "\(Int(rpm.rounded())) rpm"
    }
}

public enum FanCommand: Equatable {
    case status
    case set(Double)
    case auto
    case ping

    /// Wire format, one line: `status` | `set <int>` | `auto` | `ping`.
    public static func parse(_ line: String) -> FanCommand? {
        let tokens = line.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard let verb = tokens.first else { return nil }
        switch (verb, tokens.count) {
        case ("status", 1): return .status
        case ("auto", 1): return .auto
        case ("ping", 1): return .ping
        case ("set", 2):
            guard let rpm = Int(tokens[1]) else { return nil }
            return .set(Double(rpm))
        default: return nil
        }
    }
}

/// Replies are one JSON line each.
public enum FanReply {
    public static let ok = "{\"ok\":true}"

    public static func error(_ message: String) -> String {
        struct Body: Encodable { let error: String }
        let data = (try? JSONEncoder().encode(Body(error: message))) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

/// Reverts fans to auto when manual control has gone without a heartbeat for longer than `timeout`.
public struct FanWatchdog {
    public let timeout: TimeInterval
    private var lastTouch: Date

    /// The init time counts as the first touch.
    public init(timeout: TimeInterval = 30) {
        self.timeout = timeout
        self.lastTouch = Date()
    }

    public mutating func touch(at: Date) {
        lastTouch = at
    }

    public func shouldRevert(now: Date, manual: Bool) -> Bool {
        manual && now.timeIntervalSince(lastTouch) > timeout
    }
}

public enum SMCValue {
    /// Little-endian IEEE-754 Float32, as stored for `flt ` SMC keys.
    public static func encodeFloat(_ v: Float) -> [UInt8] {
        let bits = v.bitPattern
        return (0..<4).map { UInt8((bits >> (8 * UInt32($0))) & 0xFF) }
    }

    /// Returns NaN unless exactly 4 bytes are given.
    public static func decodeFloat(_ b: [UInt8]) -> Float {
        guard b.count == 4 else { return .nan }
        let bits = (0..<4).reduce(UInt32(0)) { $0 | (UInt32(b[$1]) << (8 * UInt32($1))) }
        return Float(bitPattern: bits)
    }

    /// Big-endian four-character code, e.g. "F0Md" -> 0x46304D64. Uses the first 4 UTF-8 bytes.
    public static func fourCC(_ s: String) -> UInt32 {
        s.utf8.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
}
