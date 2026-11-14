import Foundation

// Sensor name discovery, MacBook Pro 14" M2 Pro (Mac14,9), macOS 27.2.
//
// IOHID (PrimaryUsagePage 0xff00 / PrimaryUsage 0x0005, `Product` name) returned, with each
// name appearing on several services (values in deg C at discovery time):
//   PMU tdie0...tdie10   44.1-45.0   CPU die sensors          -> CPU (max)
//   PMU tdev1...tdev8    33.7-44.4   power-manager devices    -> Power manager (max)
//   PMU TP0s TP1s TP2s TP1g TP2g TP3g  44.0-44.9              -> Power manager
//   PMU tcal             51.85       calibration constant     -> ignored
//   gas gauge battery    31.0-32.3   battery                  -> Battery (max)
//   NAND CH0 temp        35.0        SSD                      -> SSD
//   als-temp             (no event)  ambient light sensor     -> ignored by reader
// IOHID has no GPU sensor and no Trackpad sensor on this Mac.
//
// SMC (AppleSMC, keys starting with `T`, type `flt `): GPU lives only here, in the `Tg**` keys:
//   Tg0W Tg0X Tg0e Tg0f Tg0i Tg0j Tg1g Tg1h Tg1k Tg1l   48.7-55.3
// The helper reports these as "SMC <key>" (e.g. "SMC Tg0W") -> GPU (max). No other SMC key is
// reported (hundreds of raw keys, mostly duplicates of the above or non-temperatures).
//
// Mapping rules (first match wins, case-insensitive):
//   "SMC Tg" prefix                      -> GPU
//   "PMU tdie" prefix                    -> CPU
//   "PMU tcal"                           -> ignored (calibration value, not a temperature)
//   "PMU " prefix (tdev*, TP*)           -> Power manager
//   "NAND" prefix                        -> SSD
//   contains "trackpad"                  -> Trackpad (no sensor on this Mac, so hidden here)
//   contains "gas gauge" or "battery"    -> Battery
//   anything else                        -> extra under its raw name
// Categories with no valid reading are omitted.

public struct SensorReading: Codable, Equatable {
    public let name: String
    public let celsius: Double

    public init(name: String, celsius: Double) {
        self.name = name
        self.celsius = celsius
    }
}

public struct SensorSummary: Equatable {
    public let cpu: Double?
    public let gpu: Double?
    /// `name` is the display label.
    public let extras: [SensorReading]

    public init(cpu: Double?, gpu: Double?, extras: [SensorReading]) {
        self.cpu = cpu
        self.gpu = gpu
        self.extras = extras
    }
}

public enum SensorMap {
    private enum Category: Hashable {
        case cpu, gpu, ssd, trackpad, power, battery, ignored
        case other(String)
    }

    private static func category(of name: String) -> Category {
        let n = name.lowercased()
        if n.hasPrefix("smc tg") { return .gpu }
        if n.hasPrefix("pmu tdie") { return .cpu }
        if n.hasPrefix("pmu tcal") { return .ignored }
        if n.hasPrefix("pmu ") { return .power }
        if n.hasPrefix("nand") { return .ssd }
        if n.contains("trackpad") { return .trackpad }
        if n.contains("gas gauge") || n.contains("battery") { return .battery }
        return .other(name)
    }

    public static func summarize(_ readings: [SensorReading]) -> SensorSummary {
        var best: [Category: Double] = [:]
        for reading in readings where reading.celsius > 0 && reading.celsius < 130 {
            let c = category(of: reading.name)
            if c == .ignored { continue }
            best[c] = max(best[c] ?? -.infinity, reading.celsius)
        }

        let labelled: [(Category, String)] = [
            (.ssd, "SSD"), (.trackpad, "Trackpad"), (.power, "Power manager"), (.battery, "Battery"),
        ]
        var extras = labelled.compactMap { c, label in
            best[c].map { SensorReading(name: label, celsius: $0) }
        }
        let others = best.compactMap { c, v -> SensorReading? in
            if case .other(let raw) = c { return SensorReading(name: raw, celsius: v) }
            return nil
        }
        extras += others.sorted { $0.name < $1.name }

        return SensorSummary(cpu: best[.cpu], gpu: best[.gpu], extras: extras)
    }
}
