import Foundation

/// The time zone the app speaks to OWA in: the Windows id sent as `TimeZoneContext` and the zone
/// the request bodies write their offset-less wall times in.
///
/// The two must always travel together. The server reads `RangeStart` / `TimeWindow` as wall times
/// in the zone named by the header, so formatting them in any other zone shifts the requested
/// range — and the free/busy grid, which is indexed from the window's start — by the difference.
/// That is exactly what used to happen for a Mac clock set to a zone missing from the table: the
/// header said Moscow while the dates were written in the local zone.
struct OWAServerTimeZone: Equatable, Sendable {
    /// Windows time zone id for `TimeZoneContext`, e.g. "Russian Standard Time".
    let windowsID: String
    /// Zone the request bodies format their wall times in; same rules as `windowsID`.
    let zone: TimeZone

    /// Follows the macOS clock, resolved at call time.
    static var current: OWAServerTimeZone { resolve(TimeZone.current) }

    /// Moscow, used for a zone missing from the table: the server is then told Moscow, and the
    /// dates are written in Moscow too, so the absolute times stay right. Event times come back
    /// with an explicit offset and are unaffected.
    static let fallback = OWAServerTimeZone(
        windowsID: "Russian Standard Time",
        zone: TimeZone(identifier: "Europe/Moscow") ?? TimeZone(secondsFromGMT: 3 * 3600)!
    )

    static func resolve(_ zone: TimeZone) -> OWAServerTimeZone {
        guard let windowsID = windowsIDsByIANA[zone.identifier] else { return fallback }
        return OWAServerTimeZone(windowsID: windowsID, zone: zone)
    }

    /// IANA → Windows ids, after CLDR `windowsZones.xml`. Covers every Russian zone (the display
    /// time zone picker offers them all), the CIS, and the usual travel destinations. A zone is
    /// listed only where the Windows rules match the IANA ones today.
    static let windowsIDsByIANA: [String: String] = [
        // Russia, west → east
        "Europe/Kaliningrad":  "Kaliningrad Standard Time",
        "Europe/Moscow":       "Russian Standard Time",
        "Europe/Kirov":        "Russian Standard Time",
        "Europe/Simferopol":   "Russian Standard Time",
        "Europe/Volgograd":    "Volgograd Standard Time",
        "Europe/Astrakhan":    "Astrakhan Standard Time",
        "Europe/Ulyanovsk":    "Astrakhan Standard Time",
        "Europe/Saratov":      "Saratov Standard Time",
        "Europe/Samara":       "Russia Time Zone 3",
        "Asia/Yekaterinburg":  "Ekaterinburg Standard Time",
        "Asia/Omsk":           "Omsk Standard Time",
        "Asia/Novosibirsk":    "N. Central Asia Standard Time",
        "Asia/Barnaul":        "Altai Standard Time",
        "Asia/Tomsk":          "Tomsk Standard Time",
        "Asia/Novokuznetsk":   "North Asia Standard Time",
        "Asia/Krasnoyarsk":    "North Asia Standard Time",
        "Asia/Irkutsk":        "North Asia East Standard Time",
        "Asia/Chita":          "Transbaikal Standard Time",
        "Asia/Yakutsk":        "Yakutsk Standard Time",
        "Asia/Khandyga":       "Yakutsk Standard Time",
        "Asia/Vladivostok":    "Vladivostok Standard Time",
        "Asia/Ust-Nera":       "Vladivostok Standard Time",
        "Asia/Sakhalin":       "Sakhalin Standard Time",
        "Asia/Magadan":        "Magadan Standard Time",
        "Asia/Srednekolymsk":  "Russia Time Zone 10",
        "Asia/Kamchatka":      "Russia Time Zone 11",
        "Asia/Anadyr":         "Russia Time Zone 11",

        // CIS and neighbours
        "Europe/Minsk":        "Belarus Standard Time",
        "Europe/Kyiv":         "FLE Standard Time",
        "Europe/Kiev":         "FLE Standard Time",
        "Europe/Chisinau":     "E. Europe Standard Time",
        "Asia/Tbilisi":        "Georgian Standard Time",
        "Asia/Yerevan":        "Caucasus Standard Time",
        "Asia/Baku":           "Azerbaijan Standard Time",
        "Asia/Tashkent":       "West Asia Standard Time",
        "Asia/Samarkand":      "West Asia Standard Time",
        "Asia/Dushanbe":       "West Asia Standard Time",
        "Asia/Ashgabat":       "West Asia Standard Time",
        "Asia/Bishkek":        "Central Asia Standard Time",
        "Europe/Riga":         "FLE Standard Time",
        "Europe/Tallinn":      "FLE Standard Time",
        "Europe/Vilnius":      "FLE Standard Time",
        "Europe/Helsinki":     "FLE Standard Time",
        "Europe/Istanbul":     "Turkey Standard Time",

        // Europe
        "Europe/London":       "GMT Standard Time",
        "Europe/Lisbon":       "GMT Standard Time",
        "Europe/Berlin":       "W. Europe Standard Time",
        "Europe/Amsterdam":    "W. Europe Standard Time",
        "Europe/Rome":         "W. Europe Standard Time",
        "Europe/Vienna":       "W. Europe Standard Time",
        "Europe/Zurich":       "W. Europe Standard Time",
        "Europe/Stockholm":    "W. Europe Standard Time",
        "Europe/Paris":        "Romance Standard Time",
        "Europe/Madrid":       "Romance Standard Time",
        "Europe/Brussels":     "Romance Standard Time",
        "Europe/Copenhagen":   "Romance Standard Time",
        "Europe/Prague":       "Central Europe Standard Time",
        "Europe/Budapest":     "Central Europe Standard Time",
        "Europe/Belgrade":     "Central Europe Standard Time",
        "Europe/Warsaw":       "Central European Standard Time",
        "Europe/Athens":       "GTB Standard Time",
        "Europe/Bucharest":    "GTB Standard Time",
        "Europe/Sofia":        "FLE Standard Time",

        // Asia
        "Asia/Dubai":          "Arabian Standard Time",
        "Asia/Jerusalem":      "Israel Standard Time",
        "Asia/Kolkata":        "India Standard Time",
        "Asia/Bangkok":        "SE Asia Standard Time",
        "Asia/Shanghai":       "China Standard Time",
        "Asia/Hong_Kong":      "China Standard Time",
        "Asia/Singapore":      "Singapore Standard Time",
        "Asia/Seoul":          "Korea Standard Time",
        "Asia/Tokyo":          "Tokyo Standard Time",

        // Americas
        "America/New_York":    "Eastern Standard Time",
        "America/Toronto":     "Eastern Standard Time",
        "America/Chicago":     "Central Standard Time",
        "America/Denver":      "Mountain Standard Time",
        "America/Phoenix":     "US Mountain Standard Time",
        "America/Los_Angeles": "Pacific Standard Time",

        // UTC
        "UTC":                 "UTC",
        "Etc/UTC":             "UTC",
        "GMT":                 "UTC",
    ]

    /// Offset-less wall-time formatter for request bodies, in `zone`.
    func wallTimeFormatter() -> DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = zone
        return f
    }
}
