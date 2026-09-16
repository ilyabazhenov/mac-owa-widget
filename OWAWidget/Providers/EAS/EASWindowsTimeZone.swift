import Foundation

/// A point in a Windows `SYSTEMTIME`, as used for daylight-saving transition rules.
///
/// With `year == 0` the entry is *relative*: "the `day`-th `dayOfWeek` of `month`", where a
/// `day` of 5 means the last one. That is the form Exchange sends, because a rule has to hold
/// for every year, not one.
struct EASSystemTime: Sendable, Equatable {
    let year: Int
    let month: Int
    /// 0 = Sunday.
    let dayOfWeek: Int
    /// 1…4 for the n-th occurrence, 5 for the last.
    let day: Int
    let hour: Int
    let minute: Int

    var isAbsent: Bool { month == 0 }
}

/// The `calendar:Timezone` blob: base64 of the 172-byte Win32 `TIME_ZONE_INFORMATION`.
///
/// It is needed because a recurring meeting repeats at a wall-clock time, not at a fixed
/// instant. "Every Tuesday at 10:00" means 10:00 where the organiser is, and across a daylight
/// transition that is a different moment in UTC. Expanding a series without it puts half the
/// year's occurrences an hour out.
///
/// Layout, all little-endian:
///
/// | offset | size | field |
/// |---|---|---|
/// | 0 | 4 | `Bias`, minutes |
/// | 4 | 64 | `StandardName`, UTF-16 |
/// | 68 | 16 | `StandardDate` |
/// | 84 | 4 | `StandardBias` |
/// | 88 | 64 | `DaylightName`, UTF-16 |
/// | 152 | 16 | `DaylightDate` |
/// | 168 | 4 | `DaylightBias` |
///
/// Windows states the relationship as `UTC = local + bias`, so the offset east of UTC that the
/// rest of Foundation expects is the negation.
struct EASWindowsTimeZone: Sendable, Equatable {

    /// Minutes, in the Windows sense: positive west of UTC.
    let bias: Int
    let standardBias: Int
    let daylightBias: Int
    let standardDate: EASSystemTime
    let daylightDate: EASSystemTime

    /// Whether this zone ever changes offset. Much of the world — including all of Russia since
    /// 2014 — does not, and that makes the whole transition calculation moot.
    var observesDaylightSaving: Bool {
        !standardDate.isAbsent && !daylightDate.isAbsent
    }

    // MARK: Parsing

    static func parse(base64: String?) -> EASWindowsTimeZone? {
        guard let base64, !base64.isEmpty,
              let data = Data(base64Encoded: base64),
              data.count >= 172
        else { return nil }

        let bytes = [UInt8](data)

        func int32(_ offset: Int) -> Int {
            let raw = UInt32(bytes[offset])
                | UInt32(bytes[offset + 1]) << 8
                | UInt32(bytes[offset + 2]) << 16
                | UInt32(bytes[offset + 3]) << 24
            return Int(Int32(bitPattern: raw))
        }
        func uint16(_ offset: Int) -> Int {
            Int(UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8)
        }
        func systemTime(_ offset: Int) -> EASSystemTime {
            EASSystemTime(
                year: uint16(offset),
                month: uint16(offset + 2),
                dayOfWeek: uint16(offset + 4),
                day: uint16(offset + 6),
                hour: uint16(offset + 8),
                minute: uint16(offset + 10)
            )
        }

        return EASWindowsTimeZone(
            bias: int32(0),
            standardBias: int32(84),
            daylightBias: int32(168),
            standardDate: systemTime(68),
            daylightDate: systemTime(152)
        )
    }

    // MARK: Offsets

    /// Seconds east of UTC in effect at the given *local* wall-clock time.
    func utcOffsetSeconds(forLocal components: DateComponents) -> Int {
        let extra = isDaylight(components) ? daylightBias : standardBias
        return -(bias + extra) * 60
    }

    /// Whether daylight saving is in effect at a local wall-clock time.
    ///
    /// The comparison is done in local time on purpose: that is the frame the transition rules
    /// are written in.
    func isDaylight(_ components: DateComponents) -> Bool {
        guard observesDaylightSaving else { return false }
        guard let year = components.year,
              let daylightStart = resolve(daylightDate, in: year),
              let standardStart = resolve(standardDate, in: year),
              let moment = minutesIntoYear(components)
        else { return false }

        if daylightStart < standardStart {
            // Northern hemisphere: a single daylight stretch inside the year.
            return moment >= daylightStart && moment < standardStart
        } else {
            // Southern hemisphere: the stretch wraps around the new year.
            return moment >= daylightStart || moment < standardStart
        }
    }

    // MARK: Resolving transition rules

    /// Turns a transition rule into a comparable position within `year`.
    private func resolve(_ rule: EASSystemTime, in year: Int) -> Int? {
        guard rule.month > 0 else { return nil }

        let day: Int
        if rule.year != 0 {
            // Absolute form: an explicit date, used by zones with one-off rules.
            day = rule.day
        } else {
            guard let resolved = nthWeekday(
                occurrence: rule.day,
                weekday: rule.dayOfWeek,
                month: rule.month,
                year: year
            ) else { return nil }
            day = resolved
        }

        var components = DateComponents()
        components.year = year
        components.month = rule.month
        components.day = day
        components.hour = rule.hour
        components.minute = rule.minute
        return minutesIntoYear(components)
    }

    /// Day of month for "the n-th `weekday` of this month", where 5 means the last one.
    private func nthWeekday(occurrence: Int, weekday: Int, month: Int, year: Int) -> Int? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        var first = DateComponents()
        first.year = year
        first.month = month
        first.day = 1
        guard let firstOfMonth = calendar.date(from: first),
              let range = calendar.range(of: .day, in: .month, for: firstOfMonth)
        else { return nil }

        // Calendar weekdays are 1-based with Sunday = 1; SYSTEMTIME uses 0 for Sunday.
        let firstWeekday = calendar.component(.weekday, from: firstOfMonth) - 1
        let delta = (weekday - firstWeekday + 7) % 7
        let firstMatching = 1 + delta

        if occurrence >= 5 {
            // "Last": step forward in weeks while the month still has room.
            var candidate = firstMatching
            while candidate + 7 <= range.count { candidate += 7 }
            return candidate
        }

        let candidate = firstMatching + (occurrence - 1) * 7
        return candidate <= range.count ? candidate : nil
    }

    /// A position inside the year, precise to the minute. Only ever compared with another such
    /// position from the same year, so the absolute value does not matter.
    private func minutesIntoYear(_ components: DateComponents) -> Int? {
        guard let month = components.month, let day = components.day else { return nil }
        // Fixed 31-day months: comparisons stay correct because transitions are months apart,
        // and this avoids depending on whether the year is a leap year.
        return ((month - 1) * 31 + (day - 1)) * 24 * 60
            + (components.hour ?? 0) * 60
            + (components.minute ?? 0)
    }
}

extension EASWindowsTimeZone {
    /// Converts a local wall-clock time to an instant.
    func date(fromLocal components: DateComponents) -> Date? {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let naive = utc.date(from: components) else { return nil }
        return naive.addingTimeInterval(-Double(utcOffsetSeconds(forLocal: components)))
    }

    /// The wall-clock components of an instant in this zone.
    func localComponents(from date: Date) -> DateComponents {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!

        // Two passes: the offset depends on the local time, which depends on the offset. The
        // first guess uses standard time, the second corrects it if that landed inside a
        // daylight stretch. A further pass would only matter within the transition hour itself.
        let standardGuess = date.addingTimeInterval(-Double(bias + standardBias) * 60)
        let fields: Set<Calendar.Component> = [.year, .month, .day, .hour, .minute, .second, .weekday]
        let guessed = utc.dateComponents(fields, from: standardGuess)

        let offset = utcOffsetSeconds(forLocal: guessed)
        return utc.dateComponents(fields, from: date.addingTimeInterval(Double(offset)))
    }
}

// MARK: - Encoding

extension EASWindowsTimeZone {

    /// Builds the blob a new appointment carries.
    ///
    /// Only the standard offset is described, with no daylight transitions. That is exact for
    /// zones without them — all of Russia since 2014, which is what this provider runs
    /// against — and safe for the rest, because the appointments created here are single
    /// meetings whose `StartTime` and `EndTime` are absolute UTC. The element is metadata about
    /// how to display them, not how to compute them.
    ///
    /// A recurring meeting created from here would need the real transition rules, which cannot
    /// be recovered from a Foundation `TimeZone`. Creating series is not offered, and this is
    /// one of the reasons.
    static func blob(for timeZone: TimeZone, at date: Date = Date()) -> String {
        // Windows states the relationship as `UTC = local + bias`, so the sign flips. Daylight
        // saving is subtracted out to leave the zone's standard offset.
        let offsetSeconds = timeZone.secondsFromGMT(for: date)
        let daylightSeconds = Int(timeZone.daylightSavingTimeOffset(for: date))
        let standardOffsetMinutes = (offsetSeconds - daylightSeconds) / 60

        var bytes = [UInt8](repeating: 0, count: 172)
        let bias = Int32(-standardOffsetMinutes)
        let raw = UInt32(bitPattern: bias)
        for i in 0..<4 {
            bytes[i] = UInt8((raw >> (8 * UInt32(i))) & 0xFF)
        }
        // StandardDate, StandardBias, DaylightName, DaylightDate and DaylightBias stay zero:
        // a zero month means "no transition", which is how a fixed-offset zone is expressed.
        return Data(bytes).base64EncodedString()
    }
}
