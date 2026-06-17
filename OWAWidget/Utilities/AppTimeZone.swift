import Foundation

/// Centralized "display" timezone. All UI rendering, day/range boundaries, and "today/tomorrow"
/// logic should use these helpers — NOT `TimeZone.current` / `Calendar.current` — so the app
/// presents times in the user-selected working timezone regardless of where the macOS clock is
/// set. The selection is configurable in Settings (`DisplayTimeZoneOption`) and defaults to
/// `Europe/Moscow`; "System" follows the macOS clock.
///
/// Server-side wire format (OWA `TimeZoneContext`, request body date strings) deliberately stays
/// on `TimeZone.current` because the server is told that TZ via `windowsTimezoneID()` and round-
/// trips dates against it. Decoupling display TZ from server TZ keeps absolute-time accuracy
/// while letting the UI match the user's mental model.
enum AppTimeZone {
    /// `UserDefaults` key holding the user-selected display timezone token.
    /// Shared single source of truth: `CalendarService` reads/writes it, this resolver reads it.
    static let storageKey = "displayTimeZoneIdentifier"

    /// The user's current selection, resolved from persisted storage (defaults to Moscow).
    static var option: DisplayTimeZoneOption {
        DisplayTimeZoneOption(storageValue: UserDefaults.standard.string(forKey: storageKey))
    }

    /// Configurable display timezone. Reads `UserDefaults` on each access so a settings change
    /// takes effect on the next render without restart. Defaults to `Europe/Moscow` when unset,
    /// preserving the app's original behavior for existing users.
    static var zone: TimeZone { option.resolvedTimeZone }

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
