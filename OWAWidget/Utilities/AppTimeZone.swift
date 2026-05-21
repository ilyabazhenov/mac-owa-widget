import Foundation

/// Centralized "display" timezone. All UI rendering, day/range boundaries, and "today/tomorrow"
/// logic should use these helpers — NOT `TimeZone.current` / `Calendar.current` — so the app
/// presents times in the company's working timezone (Moscow) regardless of where the user's
/// macOS clock is set.
///
/// Server-side wire format (OWA `TimeZoneContext`, request body date strings) deliberately stays
/// on `TimeZone.current` because the server is told that TZ via `windowsTimezoneID()` and round-
/// trips dates against it. Decoupling display TZ from server TZ keeps absolute-time accuracy
/// while letting the UI match the user's mental model.
enum AppTimeZone {
    /// Fixed display timezone. Bare `nonisolated(unsafe)` is safe because the underlying
    /// `TimeZone` value is immutable and Foundation marks it `Sendable` only for known instances.
    static let zone: TimeZone = TimeZone(identifier: "Europe/Moscow") ?? .gmt

    /// Calendar pre-configured with `AppTimeZone.zone` for `startOfDay`, weekday checks, etc.
    static var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        return cal
    }

    /// Short city/region abbreviation for the display timezone, e.g. "Мск" / "MSK".
    static var shortLabel: String {
        // Localized abbreviation falls back to TimeZone.abbreviation() (e.g. "GMT+3") when the
        // OS doesn't ship a short city name for the identifier.
        if let abbr = zone.localizedName(for: .shortStandard, locale: Locale.current) {
            return abbr
        }
        return zone.abbreviation() ?? zone.identifier
    }

    /// UTC-offset suffix, e.g. "UTC+3". Useful as a hover hint to disambiguate the short label.
    static var utcOffsetLabel: String {
        let seconds = zone.secondsFromGMT()
        let hours = seconds / 3600
        let sign = hours >= 0 ? "+" : "-"
        return "UTC\(sign)\(abs(hours))"
    }
}
