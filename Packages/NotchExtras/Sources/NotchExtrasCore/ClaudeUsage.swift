import Foundation

public struct UsageBucket: Equatable {
    /// Utilization in the range 0...100.
    public let percent: Double
    public let resetsAt: Date?

    public init(percent: Double, resetsAt: Date?) {
        self.percent = percent
        self.resetsAt = resetsAt
    }

    /// Utilization as of `now`: once the window's reset time has passed, the stored
    /// figure is from the previous window, so the current one starts at 0.
    public func percent(at now: Date) -> Double {
        if let resetsAt, resetsAt <= now { return 0 }
        return percent
    }
}

public struct UsageSnapshot: Equatable {
    public let fiveHour: UsageBucket?
    public let weekly: UsageBucket?
    public let weeklyModelName: String?
    public let weeklyModelBucket: UsageBucket?

    public init(
        fiveHour: UsageBucket?,
        weekly: UsageBucket?,
        weeklyModelName: String?,
        weeklyModelBucket: UsageBucket?
    ) {
        self.fiveHour = fiveHour
        self.weekly = weekly
        self.weeklyModelName = weeklyModelName
        self.weeklyModelBucket = weeklyModelBucket
    }

    public enum ParseError: Error {
        case notAnObject
    }

    /// Parses the Claude usage endpoint response. Tolerant of unknown keys and null buckets.
    public static func parse(_ data: Data) throws -> UsageSnapshot {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ParseError.notAnObject
        }

        let modelPrefix = "seven_day_"
        let ignoredModelKeys: Set<String> = ["seven_day_oauth_apps"]
        var modelName: String?
        var modelBucket: UsageBucket?
        // Sorted for deterministic selection when several model buckets are present.
        for key in root.keys.sorted() where key.hasPrefix(modelPrefix) && !ignoredModelKeys.contains(key) {
            if let bucket = bucket(root[key]) {
                modelName = String(key.dropFirst(modelPrefix.count)).capitalized
                modelBucket = bucket
                break
            }
        }

        return UsageSnapshot(
            fiveHour: bucket(root["five_hour"]),
            weekly: bucket(root["seven_day"]),
            weeklyModelName: modelName,
            weeklyModelBucket: modelBucket
        )
    }

    private static func bucket(_ value: Any?) -> UsageBucket? {
        guard let dict = value as? [String: Any],
              let utilization = (dict["utilization"] as? NSNumber)?.doubleValue else { return nil }
        let reset = (dict["resets_at"] as? String).flatMap(parseDate)
        return UsageBucket(percent: min(max(utilization, 0), 100), resetsAt: reset)
    }

    private static func parseDate(_ string: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: string) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }
}

public enum UsageLevel {
    case normal, warning, critical

    public static func of(_ percent: Double) -> UsageLevel {
        if percent > 90 { return .critical }
        if percent > 70 { return .warning }
        return .normal
    }
}

/// Human-readable reset time: relative under 24 h, otherwise weekday and clock time.
public func resetText(_ date: Date?, now: Date, calendar: Calendar = .current) -> String {
    guard let date else { return "" }
    let interval = date.timeIntervalSince(now)
    if interval <= 0 { return "reset" }
    if interval < 24 * 3600 {
        let totalMinutes = max(0, Int(interval / 60))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return hours > 0 ? "resets in \(hours)h \(minutes)m" : "resets in \(minutes)m"
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    formatter.dateFormat = "EEE HH:mm"
    return "resets \(formatter.string(from: date))"
}

/// "just now", "12m ago", "14h ago", "2d ago".
public func updatedAgoText(_ date: Date, now: Date) -> String {
    let minutes = Int(max(0, now.timeIntervalSince(date)) / 60)
    if minutes < 1 { return "just now" }
    if minutes < 60 { return "\(minutes)m ago" }
    let hours = minutes / 60
    if hours < 24 { return "\(hours)h ago" }
    return "\(hours / 24)d ago"
}
