import Foundation

/// `calendar:Recurrence/Type`. 4 is not assigned.
enum EASRecurrenceKind: Int, Codable, Sendable {
    case daily = 0
    case weekly = 1
    /// The n-th day of the month.
    case monthlyByDay = 2
    /// The n-th weekday of the month — "the last Friday", "the first weekday".
    case monthlyByWeekday = 3
    case yearlyByDate = 5
    case yearlyByWeekday = 6
}

/// A repetition rule as ActiveSync states it.
///
/// The server sends the rule, never the occurrences. Everything the calendar actually shows for
/// a series is produced locally by ``EASRecurrenceExpander``.
struct EASRecurrence: Codable, Sendable, Hashable {
    var kind: EASRecurrenceKind
    var interval: Int
    /// Inclusive end of the series, if it has one.
    var until: Date?
    /// Total number of occurrences, counted from the series start — including any that fall
    /// outside the window being displayed.
    var occurrences: Int?
    /// Bit mask: 1 Sunday, 2 Monday, 4 Tuesday, 8 Wednesday, 16 Thursday, 32 Friday, 64 Saturday.
    /// 62 means "any weekday" and 127 "every day", which is why this is read as a mask rather
    /// than a single day.
    var dayOfWeekMask: Int?
    var dayOfMonth: Int?
    /// 1…4 for the n-th week, 5 for the last one.
    var weekOfMonth: Int?
    var monthOfYear: Int?
    /// 0 = Sunday. Decides which week a day belongs to when counting intervals.
    var firstDayOfWeek: Int?
}

/// One occurrence the organiser changed or removed.
///
/// `originalStart` is the identity — where the occurrence would have been under the rule — so a
/// meeting that was moved keeps the same identity as the slot it came from.
struct EASException: Codable, Sendable, Hashable {
    var originalStart: Date
    var isDeleted: Bool

    var start: Date?
    var end: Date?
    var subject: String?
    var location: String?
    var isAllDay: Bool?
    var bodyText: String?
    var meetingStatus: Int?
    var responseType: Int?
    var onlineMeetingConfLink: String?
    var attendees: [EASAttendee]?
}

/// A concrete instance produced from a rule.
struct EASOccurrence: Sendable, Equatable {
    /// Where the rule put it. Stays fixed even when the occurrence was moved, because the whole
    /// app keys events by identity and a moved meeting is still the same meeting.
    let originalStart: Date
    /// Where it actually is, after any override.
    let start: Date
    let end: Date
    let exception: EASException?
}

// MARK: - Shared calendar arithmetic

enum EASCalendarMath {

    /// Day of the month for "the `occurrence`-th day matching `weekdayMask`", with 5 meaning
    /// the last one.
    ///
    /// Matches on a mask rather than one weekday because Exchange uses the same field for both:
    /// "first Monday" arrives as mask 2, "first weekday" as mask 62.
    static func dayOfMonth(
        occurrence: Int,
        weekdayMask: Int,
        month: Int,
        year: Int
    ) -> Int? {
        guard weekdayMask != 0, (1...12).contains(month) else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        var first = DateComponents()
        first.year = year
        first.month = month
        first.day = 1
        guard let firstOfMonth = calendar.date(from: first),
              let range = calendar.range(of: .day, in: .month, for: firstOfMonth)
        else { return nil }

        let firstWeekday = calendar.component(.weekday, from: firstOfMonth) - 1   // 0 = Sunday
        let matching = range.compactMap { day -> Int? in
            let weekday = (firstWeekday + day - 1) % 7
            return (weekdayMask & (1 << weekday)) != 0 ? day : nil
        }
        guard !matching.isEmpty else { return nil }

        if occurrence >= 5 { return matching.last }
        let index = occurrence - 1
        return matching.indices.contains(index) ? matching[index] : nil
    }

    /// Whether a weekday — 0 for Sunday, as ActiveSync counts them — is in the mask.
    static func mask(_ weekdayMask: Int, contains weekday: Int) -> Bool {
        (weekdayMask & (1 << weekday)) != 0
    }

    static func daysInMonth(year: Int, month: Int) -> Int? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = 1
        guard let date = calendar.date(from: components),
              let range = calendar.range(of: .day, in: .month, for: date)
        else { return nil }
        return range.count
    }
}
