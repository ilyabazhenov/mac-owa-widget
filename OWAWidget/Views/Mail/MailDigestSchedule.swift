import Foundation

/// The calendar half of the mail overview: today's load, the meeting up next and who of the
/// watched colleagues is free. Built from what the app already holds in memory — the synced
/// events and the downloaded free/busy grid — so the overview makes no request for it. Pure, so
/// it is tested without the window.
enum MailDigestSchedule {
    /// Free time shorter than this is not worth naming: it is the walk between two rooms.
    static let minimumFreeWindow: TimeInterval = 30 * 60

    // MARK: Today's load

    struct DayLoad: Equatable {
        struct Block: Equatable {
            let interval: DateInterval
            let isOver: Bool
        }

        let meetingCount: Int
        /// Time in meetings, parallel meetings counted once.
        let meetingSeconds: TimeInterval
        /// Meetings not over yet, the one in progress included.
        let remainingCount: Int
        /// Free time left today within working hours, from now on, at least `minimumFreeWindow` long.
        let freeWindows: [DateInterval]
        /// True when the last free window runs to the end of the working day ("after 17:30").
        let lastWindowRunsToEndOfDay: Bool
        let blocks: [Block]
        let overlaps: [DateInterval]
        /// The span the strip draws: working hours, widened to whole hours around early and late meetings.
        let axis: DateInterval
    }

    /// `nil` on a day without meetings: the line would only say so.
    ///
    /// Counts what `get_schedule_stats` counts — declined, cancelled and all-day meetings left
    /// out, unanswered invitations kept, since they hold the time on the calendar.
    static func dayLoad(
        events: [CalendarEvent],
        now: Date,
        calendar: Calendar = AppTimeZone.calendar,
        options: ScheduleStatsCalculator.Options = .init()
    ) -> DayLoad? {
        let dayStart = calendar.startOfDay(for: now)
        guard let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return nil }
        let day = DateInterval(start: dayStart, end: nextDay)
        let stats = ScheduleStatsCalculator.compute(events: events, range: day, calendar: calendar, options: options)
        guard stats.meetingCount > 0 else { return nil }

        let meetings = counted(events, in: day)
        let intervals = meetings.map { DateInterval(start: max($0.startDate, dayStart), end: min($0.endDate, nextDay)) }

        let workStart = dayStart.addingTimeInterval(TimeInterval(options.workStartMinute * 60))
        let workEnd = dayStart.addingTimeInterval(TimeInterval(options.workEndMinute * 60))
        var freeWindows: [DateInterval] = []
        var cursor = max(now, workStart)
        for busy in ScheduleStatsCalculator.union(intervals) where cursor < workEnd {
            if busy.start > cursor {
                freeWindows.append(DateInterval(start: cursor, end: min(busy.start, workEnd)))
            }
            cursor = max(cursor, busy.end)
        }
        if cursor < workEnd { freeWindows.append(DateInterval(start: cursor, end: workEnd)) }
        freeWindows = freeWindows.filter { $0.duration >= minimumFreeWindow }

        let earliest = min(workStart, intervals.map(\.start).min() ?? workStart)
        let latest = max(workEnd, intervals.map(\.end).max() ?? workEnd)
        let axisStart = calendar.dateInterval(of: .hour, for: earliest)?.start ?? earliest
        let lastHour = calendar.dateInterval(of: .hour, for: latest)
        let axisEnd = lastHour.map { $0.start == latest ? latest : $0.end } ?? latest

        return DayLoad(
            meetingCount: stats.meetingCount,
            meetingSeconds: stats.meetingSeconds,
            remainingCount: meetings.filter { $0.endDate > now }.count,
            freeWindows: freeWindows,
            lastWindowRunsToEndOfDay: freeWindows.last?.end == workEnd,
            blocks: zip(meetings, intervals).map { DayLoad.Block(interval: $1, isOver: $0.endDate <= now) },
            overlaps: stats.overlaps.map(\.interval),
            axis: DateInterval(start: max(axisStart, dayStart), end: min(axisEnd, nextDay))
        )
    }

    /// The meetings the load counts, in order of start.
    private static func counted(_ events: [CalendarEvent], in day: DateInterval) -> [CalendarEvent] {
        events
            .filter {
                !$0.isAllDay && !$0.isEffectivelyCancelled && $0.responseType != .declined
                    && $0.endDate > $0.startDate && $0.startDate < day.end && $0.endDate > day.start
            }
            .sorted { ($0.startDate, $0.endDate) < ($1.startDate, $1.endDate) }
    }

    // MARK: Up next

    enum NextUp: Equatable {
        /// A meeting is on now; `next` is the one after it today, if any.
        case inProgress(CalendarEvent, next: CalendarEvent?)
        /// The next meeting today.
        case upcoming(CalendarEvent)
        /// Nothing more today: the first meeting of a later day, within the synced window.
        case laterDay(CalendarEvent)
    }

    /// Picks the meeting the way the popover banner does: one starting within five minutes wins
    /// over one already running (people leave a meeting for the next one), and of meetings
    /// starting together the one with a join link comes first. Declined meetings are not next.
    static func nextUp(events: [CalendarEvent], now: Date, calendar: Calendar = AppTimeZone.calendar) -> NextUp? {
        let relevant = events.filter { !$0.isAllDay && !$0.isEffectivelyCancelled && $0.responseType != .declined }
        let upcoming = NextMeetingGroupPolicy.upcomingGroup(from: relevant, now: now).first
        let happening = relevant
            .filter { NextMeetingGroupPolicy.isHappening($0, now: now) }
            .sorted { ($0.joinURL != nil ? 0 : 1, $0.startDate) < ($1.joinURL != nil ? 0 : 1, $1.startDate) }
            .first
        let upcomingToday = upcoming.flatMap { calendar.isDate($0.startDate, inSameDayAs: now) ? $0 : nil }

        if let happening {
            if let upcomingToday, upcomingToday.startDate.timeIntervalSince(now) <= NextMeetingGroupPolicy.groupingWindow {
                return .upcoming(upcomingToday)
            }
            return .inProgress(happening, next: upcomingToday)
        }
        if let upcomingToday { return .upcoming(upcomingToday) }
        return upcoming.map { .laterDay($0) }
    }

    // MARK: Colleagues

    /// Free first, then tentative, busy and away, each in the user's own order. Colleagues whose
    /// calendar cannot be read are left out: the overview has nothing to say about them.
    static func orderedColleagues<Item>(_ items: [Item], presence: (Item) -> ColleaguePresence) -> [Item] {
        let rank: [ColleaguePresence: Int] = [.free: 0, .tentative: 1, .busy: 2, .away: 3]
        return items.enumerated()
            .compactMap { offset, item in rank[presence(item)].map { (rank: $0, offset: offset, item: item) } }
            .sorted { ($0.rank, $0.offset) < ($1.rank, $1.offset) }
            .map(\.item)
    }
}
