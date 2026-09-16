import Foundation

/// The zone a series repeats in.
enum EASZone: Sendable {
    case windows(EASWindowsTimeZone)
    case foundation(TimeZone)

    /// Falls back to a plain zone when the blob is missing or unreadable. A wrong zone shifts
    /// occurrences by an hour; no zone at all would drop the series entirely, which is worse.
    static func resolve(_ base64: String?, fallback: TimeZone = .current) -> EASZone {
        if let parsed = EASWindowsTimeZone.parse(base64: base64) { return .windows(parsed) }
        return .foundation(fallback)
    }

    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    func localComponents(from date: Date) -> DateComponents {
        switch self {
        case .windows(let zone):
            return zone.localComponents(from: date)
        case .foundation(let zone):
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            return calendar.dateComponents(
                [.year, .month, .day, .hour, .minute, .second, .weekday], from: date
            )
        }
    }

    /// Converts a wall-clock time to an instant.
    ///
    /// A wall time that does not exist — the hour skipped when clocks go forward — is moved
    /// forward by Foundation, and one that happens twice resolves to the first. Both are
    /// acceptable for a calendar; neither loses a meeting.
    func date(fromLocal components: DateComponents) -> Date? {
        switch self {
        case .windows(let zone):
            return zone.date(fromLocal: components)
        case .foundation(let zone):
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            return calendar.date(from: components)
        }
    }
}

/// Turns a repetition rule into the occurrences that fall inside a window.
///
/// ActiveSync sends a series as one master plus a list of exceptions and never as instances, so
/// this is the only thing standing between a weekly meeting and it appearing once, at the wrong
/// time, forever.
enum EASRecurrenceExpander {

    /// Hard ceiling on generated occurrences.
    ///
    /// Not defensive decoration: a rule with neither `Until` nor `Occurrences` — which is legal
    /// and common for "every weekday, forever" — has no natural end, and this runs inside the
    /// synchronisation path.
    static let occurrenceCap = 2000

    /// A cheap pre-expansion filter.
    ///
    /// A calendar accumulates thousands of past meetings over the years, while the widget window
    /// is `[-7 days, +30 days]`. Expanding every item only to discard almost all of them means
    /// paying for all history on every synchronization pass.
    ///
    /// The check is deliberately conservative: uncertainty favours expansion. Skipping a meeting
    /// here loses it from the calendar, while expanding once too often costs microseconds.
    static func mayProduceOccurrences(_ item: EASCalendarItem, in window: DateInterval) -> Bool {
        guard let start = item.start, let end = item.end else { return false }
        let duration = max(end.timeIntervalSince(start), 60)

        // A moved occurrence can land anywhere, including outside the rule; that is precisely
        // the case where the meeting would otherwise disappear without a trace.
        for exception in item.exceptions where !exception.isDeleted {
            let movedStart = exception.start ?? exception.originalStart
            let movedEnd = exception.end ?? movedStart.addingTimeInterval(duration)
            if movedStart < window.end && window.start < movedEnd { return true }
        }

        guard let recurrence = item.recurrence else {
            return start < window.end && window.start < end
        }

        // A series cannot begin after the window ends.
        if start >= window.end { return false }

        // Nor can it reach the window if it ended earlier. `Until` limits the final occurrence's
        // start, so its duration is added.
        if let until = recurrence.until,
           until.addingTimeInterval(duration) <= window.start {
            return false
        }

        return true
    }

    static func expand(
        _ item: EASCalendarItem,
        in window: DateInterval,
        fallbackZone: TimeZone = .current
    ) -> [EASOccurrence] {
        guard mayProduceOccurrences(item, in: window) else { return [] }
        guard let start = item.start, let end = item.end else { return [] }
        let duration = max(end.timeIntervalSince(start), 60)

        guard let recurrence = item.recurrence else {
            let single = EASOccurrence(originalStart: start, start: start, end: end, exception: nil)
            return overlaps(single, window) ? [single] : []
        }

        let zone = EASZone.resolve(item.timezone, fallback: fallbackZone)
        let starts = generateStarts(
            recurrence: recurrence,
            seriesStart: start,
            zone: zone,
            windowEnd: window.end
        )

        var overrides: [Int: EASException] = [:]
        for exception in item.exceptions {
            overrides[key(exception.originalStart)] = exception
        }

        var occurrences: [EASOccurrence] = []
        var matched: Set<Int> = []

        for originalStart in starts {
            let identity = key(originalStart)
            guard let override = overrides[identity] else {
                occurrences.append(
                    EASOccurrence(
                        originalStart: originalStart,
                        start: originalStart,
                        end: originalStart.addingTimeInterval(duration),
                        exception: nil
                    )
                )
                continue
            }

            matched.insert(identity)
            guard !override.isDeleted else { continue }
            occurrences.append(applied(override, originalStart: originalStart, duration: duration))
        }

        // An exception whose slot was never generated must still be shown. This is the case
        // that quietly loses meetings: the organiser moves one occurrence far enough that its
        // original slot falls outside the generated range, and dropping it makes the meeting
        // vanish from the calendar without a trace.
        for exception in item.exceptions where !matched.contains(key(exception.originalStart)) {
            guard !exception.isDeleted else { continue }
            occurrences.append(
                applied(exception, originalStart: exception.originalStart, duration: duration)
            )
        }

        return occurrences
            .filter { overlaps($0, window) }
            .sorted { $0.start < $1.start }
    }

    // MARK: Applying an override

    private static func applied(
        _ exception: EASException,
        originalStart: Date,
        duration: TimeInterval
    ) -> EASOccurrence {
        let start = exception.start ?? originalStart
        let end = exception.end ?? start.addingTimeInterval(duration)
        return EASOccurrence(
            // Identity stays with the slot the rule produced, not where the meeting moved to.
            originalStart: originalStart,
            start: start,
            end: end > start ? end : start.addingTimeInterval(duration),
            exception: exception
        )
    }

    /// Whole seconds: `ExceptionStartTime` and a generated start describe the same instant, but
    /// only to the second the server stated it in.
    private static func key(_ date: Date) -> Int {
        Int(date.timeIntervalSince1970.rounded())
    }

    private static func overlaps(_ occurrence: EASOccurrence, _ window: DateInterval) -> Bool {
        // The project's half-open criterion for two intervals meeting.
        occurrence.start < window.end && window.start < occurrence.end
    }

    // MARK: Generating slots

    private static func generateStarts(
        recurrence: EASRecurrence,
        seriesStart: Date,
        zone: EASZone,
        windowEnd: Date
    ) -> [Date] {
        let seed = zone.localComponents(from: seriesStart)
        guard let seedYear = seed.year, let seedMonth = seed.month, let seedDay = seed.day else {
            return []
        }

        var starts: [Date] = []
        var produced = 0

        /// Returns false when generation should stop.
        func emit(_ date: Date) -> Bool {
            if let until = recurrence.until, date > until { return false }
            produced += 1
            if let limit = recurrence.occurrences, produced > limit { return false }
            starts.append(date)
            // Everything after this point is later still, so the window's end is a stop, not a skip.
            if date >= windowEnd { return false }
            return starts.count < occurrenceCap
        }

        func time(_ components: inout DateComponents) {
            components.hour = seed.hour
            components.minute = seed.minute
            components.second = seed.second
        }

        switch recurrence.kind {

        case .daily:
            var step = 0
            while step < occurrenceCap {
                var candidate = DateComponents()
                candidate.year = seedYear
                candidate.month = seedMonth
                // Day overflow is normalised by `Calendar`, which is exactly right here.
                candidate.day = seedDay + step * recurrence.interval
                time(&candidate)
                guard let date = zone.date(fromLocal: candidate) else { break }
                if !emit(date) { break }
                step += 1
            }

        case .weekly:
            let mask = recurrence.dayOfWeekMask ?? 0
            let firstDayOfWeek = recurrence.firstDayOfWeek ?? 0
            // 0 = Sunday, matching how ActiveSync counts and how `weekday` is normalised below.
            let seedWeekday = ((seed.weekday ?? 1) - 1)
            let effectiveMask = mask != 0 ? mask : (1 << seedWeekday)

            // Start of the week the series begins in, so interval counting has a fixed origin.
            let offsetIntoWeek = (seedWeekday - firstDayOfWeek + 7) % 7

            var week = 0
            outer: while week < occurrenceCap {
                for dayInWeek in 0..<7 {
                    let weekday = (firstDayOfWeek + dayInWeek) % 7
                    guard EASCalendarMath.mask(effectiveMask, contains: weekday) else { continue }

                    var candidate = DateComponents()
                    candidate.year = seedYear
                    candidate.month = seedMonth
                    candidate.day = seedDay - offsetIntoWeek
                        + week * 7 * recurrence.interval + dayInWeek
                    time(&candidate)

                    guard let date = zone.date(fromLocal: candidate) else { continue }
                    // The first week can contain days before the series began.
                    guard date >= seriesStart else { continue }
                    if !emit(date) { break outer }
                }
                week += 1
            }

        case .monthlyByDay, .monthlyByWeekday:
            var step = 0
            while step < occurrenceCap {
                let monthsFromSeed = seedMonth - 1 + step * recurrence.interval
                let year = seedYear + monthsFromSeed / 12
                let month = monthsFromSeed % 12 + 1

                let day: Int?
                if recurrence.kind == .monthlyByDay {
                    let wanted = recurrence.dayOfMonth ?? seedDay
                    // A month too short for the rule is skipped, not rolled into the next one.
                    day = (EASCalendarMath.daysInMonth(year: year, month: month) ?? 0) >= wanted
                        ? wanted : nil
                } else {
                    day = EASCalendarMath.dayOfMonth(
                        occurrence: recurrence.weekOfMonth ?? 1,
                        weekdayMask: recurrence.dayOfWeekMask ?? 0,
                        month: month,
                        year: year
                    )
                }

                if let day {
                    var candidate = DateComponents()
                    candidate.year = year
                    candidate.month = month
                    candidate.day = day
                    time(&candidate)
                    if let date = zone.date(fromLocal: candidate) {
                        if !emit(date) { break }
                    }
                }
                step += 1
            }

        case .yearlyByDate, .yearlyByWeekday:
            var step = 0
            while step < occurrenceCap {
                let year = seedYear + step * recurrence.interval
                let month = recurrence.monthOfYear ?? seedMonth

                let day: Int?
                if recurrence.kind == .yearlyByDate {
                    let wanted = recurrence.dayOfMonth ?? seedDay
                    day = (EASCalendarMath.daysInMonth(year: year, month: month) ?? 0) >= wanted
                        ? wanted : nil
                } else {
                    day = EASCalendarMath.dayOfMonth(
                        occurrence: recurrence.weekOfMonth ?? 1,
                        weekdayMask: recurrence.dayOfWeekMask ?? 0,
                        month: month,
                        year: year
                    )
                }

                if let day {
                    var candidate = DateComponents()
                    candidate.year = year
                    candidate.month = month
                    candidate.day = day
                    time(&candidate)
                    if let date = zone.date(fromLocal: candidate) {
                        if !emit(date) { break }
                    }
                }
                step += 1
            }
        }

        return starts
    }
}
