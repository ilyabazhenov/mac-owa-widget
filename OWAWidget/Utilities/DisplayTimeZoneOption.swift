import Foundation

/// User-selectable display timezone. `.system` follows the macOS clock; the rest are a
/// curated list of Russian working zones (UTC+2…+12). Persisted as a stable string token
/// in `UserDefaults` and resolved to a concrete `TimeZone` by ``AppTimeZone``.
enum DisplayTimeZoneOption: Identifiable, Hashable, Sendable {
    /// Follow the user's macOS timezone, resolved at render time.
    case system
    /// A fixed IANA timezone, e.g. `Europe/Moscow`.
    case fixed(String)

    /// Token used when persisting the `.system` case.
    static let systemToken = "system"

    /// Curated Russian working timezones, west→east (UTC+2…+12).
    static let curatedIdentifiers: [String] = [
        "Europe/Kaliningrad",   // UTC+2
        "Europe/Moscow",        // UTC+3
        "Europe/Samara",        // UTC+4
        "Asia/Yekaterinburg",   // UTC+5
        "Asia/Omsk",            // UTC+6
        "Asia/Krasnoyarsk",     // UTC+7
        "Asia/Irkutsk",         // UTC+8
        "Asia/Yakutsk",         // UTC+9
        "Asia/Vladivostok",     // UTC+10
        "Asia/Magadan",         // UTC+11
        "Asia/Kamchatka",       // UTC+12
    ]

    /// All options offered in the settings picker: "System" first, then the curated list.
    static var selectable: [DisplayTimeZoneOption] {
        [.system] + curatedIdentifiers.map { .fixed($0) }
    }

    /// Default when nothing is stored — preserves pre-feature behavior (Moscow).
    static let defaultOption: DisplayTimeZoneOption = .fixed("Europe/Moscow")

    var id: String { storageValue }

    /// Stable token persisted in `UserDefaults`.
    var storageValue: String {
        switch self {
        case .system: return Self.systemToken
        case .fixed(let identifier): return identifier
        }
    }

    /// Reconstructs an option from its persisted token, falling back to ``defaultOption``
    /// for nil / empty / unknown identifiers so a bad value can never break rendering.
    init(storageValue: String?) {
        guard let raw = storageValue, !raw.isEmpty else {
            self = Self.defaultOption
            return
        }
        if raw == Self.systemToken {
            self = .system
        } else if TimeZone(identifier: raw) != nil {
            self = .fixed(raw)
        } else {
            self = Self.defaultOption
        }
    }

    /// Concrete timezone used for rendering. `.system` resolves against the current clock
    /// at call time so a later system change is reflected without re-selecting.
    var resolvedTimeZone: TimeZone {
        switch self {
        case .system: return TimeZone.current
        case .fixed(let identifier): return TimeZone(identifier: identifier) ?? .gmt
        }
    }

    /// Localization key for the option's display name (city, or "system").
    var localizationKey: String {
        switch self {
        case .system:
            return "timezone.option.system"
        case .fixed(let identifier):
            let slug = identifier.split(separator: "/").last.map(String.init)?.lowercased()
                ?? identifier.lowercased()
            return "timezone.city.\(slug)"
        }
    }

    /// Current UTC-offset suffix for the resolved zone, e.g. "UTC+3". Computed live so it
    /// stays correct across DST for zones that observe it.
    var utcOffsetLabel: String {
        let seconds = resolvedTimeZone.secondsFromGMT()
        let sign = seconds >= 0 ? "+" : "-"
        let absSeconds = abs(seconds)
        let hours = absSeconds / 3600
        let minutes = (absSeconds % 3600) / 60
        if minutes == 0 {
            return "UTC\(sign)\(hours)"
        }
        return String(format: "UTC%@%d:%02d", sign, hours, minutes)
    }
}
