import Foundation
import OWAWidgetMCPShared
import os.log

/// ISO 8601 in and out of the app's display time zone (`AppTimeZone`).
///
/// Output always carries the offset ("2026-10-05T10:00:00+03:00"). Input accepts a full
/// timestamp with an offset or `Z`, a local date-time without one, or a bare date — the last two
/// are read in the display zone, which is the zone the user sees the calendar in.
///
/// One instance per tool call: formatters are among the costliest Foundation objects to create,
/// and a 300-event list formats some 600 dates.
final class MCPDateCoder {
    let timeZone: TimeZone
    let calendar: Calendar
    private let output: ISO8601DateFormatter
    private let inputWithOffset: ISO8601DateFormatter
    private let inputWithFraction: ISO8601DateFormatter
    private lazy var localDateTimeFormatters: [DateFormatter] = [
        "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm",
    ].map(localFormatter)
    private lazy var localDateFormatter = localFormatter("yyyy-MM-dd")

    init(timeZone: TimeZone = AppTimeZone.zone) {
        self.timeZone = timeZone
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = Locale(identifier: "en_US_POSIX")
        self.calendar = calendar

        output = ISO8601DateFormatter()
        output.timeZone = timeZone
        output.formatOptions = [.withInternetDateTime]
        inputWithOffset = ISO8601DateFormatter()
        inputWithOffset.formatOptions = [.withInternetDateTime]
        inputWithFraction = ISO8601DateFormatter()
        inputWithFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    func string(_ date: Date) -> String {
        output.string(from: date)
    }

    func dayString(_ date: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    enum Bound { case start, end }

    /// Parses an input date. A bare date as an `.end` bound means the end of that day, so
    /// `from: 2026-10-05, to: 2026-10-05` covers the whole day.
    func parse(_ text: String, as bound: Bound) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let date = inputWithOffset.date(from: trimmed) ?? inputWithFraction.date(from: trimmed) {
            return date
        }
        for formatter in localDateTimeFormatters {
            if let date = formatter.date(from: trimmed) { return date }
        }
        if let day = localDateFormatter.date(from: trimmed) {
            let start = calendar.startOfDay(for: day)
            return bound == .start ? start : calendar.date(byAdding: .day, value: 1, to: start)
        }
        return nil
    }

    /// "HH:mm" -> minutes after midnight.
    static func minuteOfDay(_ text: String) -> Int? {
        let parts = text.split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...24).contains(hour), (0..<60).contains(minute), hour * 60 + minute <= 24 * 60 else { return nil }
        return hour * 60 + minute
    }

    private func localFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.calendar = calendar
        formatter.dateFormat = format
        formatter.isLenient = false
        return formatter
    }
}

/// Short, stable handles for events. Exchange ItemIds are ~150 base64 characters: costly in
/// tokens and easy for a model to mangle when copying back. The handle is derived from the id, so
/// it is the same across syncs and needs no per-connection state.
enum MCPEventID {
    static func short(_ eventID: String) -> String {
        MCPShortHash.hex(eventID, bytes: 6)
    }

    /// Accepts the short handle or the full id.
    static func resolve(_ handle: String, in events: [CalendarEvent]) -> CalendarEvent? {
        let trimmed = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        if let exact = events.first(where: { $0.id == trimmed }) { return exact }
        let lowered = trimmed.lowercased()
        return events.first { short($0.id) == lowered }
    }
}

/// Requests per minute, refilled continuously. Time is injected for tests.
struct MCPTokenBucket: Sendable {
    let capacity: Double
    let refillPerSecond: Double
    private(set) var tokens: Double
    private var updatedAt: Date

    init(capacity: Int, perMinute: Int, now: Date) {
        self.capacity = Double(capacity)
        self.refillPerSecond = Double(perMinute) / 60
        self.tokens = Double(capacity)
        self.updatedAt = now
    }

    mutating func take(now: Date) -> Bool {
        take(1, now: now)
    }

    /// All `count` tokens or none.
    mutating func take(_ count: Int, now: Date) -> Bool {
        let elapsed = max(0, now.timeIntervalSince(updatedAt))
        tokens = min(capacity, tokens + elapsed * refillPerSecond)
        updatedAt = now
        guard tokens >= Double(count) else { return false }
        tokens -= Double(count)
        return true
    }
}

/// File log for development (`make run` builds DEBUG): `~/Library/Logs/OWAWidget/mcp.log`, per AGENTS.md.
enum MCPDebugLog {
    static let logger = Logger(subsystem: "com.owawidget", category: "MCP")

    #if DEBUG
    private static let name = "mcp.log"

    static func reset() {
        DebugTextLog.reset(name, with: "=== MCP Log started \(Date()) ===\n")
    }

    static func write(_ message: String) {
        DebugTextLog.append(message, to: name)
    }
    #else
    static func reset() {}
    static func write(_ message: String) {}
    #endif

    static func log(_ message: String) {
        logger.info("\(message, privacy: .public)")
        write(message)
    }
}
