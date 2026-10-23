import Foundation

/// Which meetings count as "next", shared by the popover banner and the MCP server.
///
/// Meetings starting within five minutes of each other form one group (people double-book), and
/// within a group the ones with a join link come first. Takes `now` explicitly:
/// `CalendarEvent.isHappeningNow` reads the system clock, which makes tests depend on wall time.
enum NextMeetingGroupPolicy {
    static let groupingWindow: TimeInterval = 5 * 60
    static let bannerHorizon: TimeInterval = 30 * 60

    /// The popover banner: nothing unless the earliest candidate is in progress or starts within
    /// 30 minutes. A meeting starting within five minutes is promoted over one already running.
    static func bannerGroup(from events: [CalendarEvent], now: Date) -> [CalendarEvent] {
        let candidates = events
            .filter { !$0.isAllDay && !$0.isEffectivelyCancelled && ($0.startDate > now || isHappening($0, now: now)) }
            .sorted { $0.startDate < $1.startDate }

        guard let earliest = candidates.first else { return [] }
        guard earliest.startDate.timeIntervalSince(now) <= bannerHorizon || isHappening(earliest, now: now) else {
            return []
        }

        let promoted = candidates.first {
            !isHappening($0, now: now) && $0.startDate.timeIntervalSince(now) <= groupingWindow
        }
        return group(around: promoted ?? earliest, in: candidates)
    }

    /// The next meetings that have not started yet, with no horizon: at 22:00 the answer to
    /// "what's next" is tomorrow's first meeting. Callers filter out what they do not want
    /// counted (declined meetings, other accounts) beforehand.
    static func upcomingGroup(from events: [CalendarEvent], now: Date) -> [CalendarEvent] {
        let candidates = events
            .filter { !$0.isAllDay && !$0.isEffectivelyCancelled && $0.startDate > now }
            .sorted { $0.startDate < $1.startDate }
        guard let earliest = candidates.first else { return [] }
        return group(around: earliest, in: candidates)
    }

    /// The first meeting of a later day once today has nothing left — none running, none still
    /// to start — or `nil` while today still has one. The popover says so in the evening instead
    /// of showing an empty grid under a meeting that ended hours ago.
    static func nextAfterToday(from events: [CalendarEvent], now: Date, calendar: Calendar) -> CalendarEvent? {
        let candidates = events
            .filter { !$0.isAllDay && !$0.isEffectivelyCancelled && ($0.startDate > now || isHappening($0, now: now)) }
            .sorted { $0.startDate < $1.startDate }
        guard let first = candidates.first,
              !isHappening(first, now: now),
              !calendar.isDate(first.startDate, inSameDayAs: now)
        else { return nil }
        return first
    }

    static func isHappening(_ event: CalendarEvent, now: Date) -> Bool {
        event.startDate <= now && event.endDate > now
    }

    private static func group(around reference: CalendarEvent, in candidates: [CalendarEvent]) -> [CalendarEvent] {
        candidates
            .filter { abs($0.startDate.timeIntervalSince(reference.startDate)) <= groupingWindow }
            .sorted { ($0.joinURL != nil ? 0 : 1) < ($1.joinURL != nil ? 0 : 1) }
    }
}
