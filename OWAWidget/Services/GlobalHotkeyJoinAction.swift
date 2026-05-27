import Foundation

enum GlobalHotkeyJoinAction {
    /// Meetings are considered joinable when:
    /// - they are not all-day
    /// - have a join URL available for actions
    /// - are happening now or start in the next 2 minutes
    static func candidates(from events: [CalendarEvent], now: Date) -> [CalendarEvent] {
        let joinable = events.filter { event in
            guard !event.isAllDay else { return false }
            guard !event.isEffectivelyCancelled else { return false }
            guard event.joinURLForActions != nil else { return false }

            if event.startDate <= now, event.endDate > now { return true }

            let secondsUntilStart = event.startDate.timeIntervalSince(now)
            return secondsUntilStart >= 0 && secondsUntilStart <= 2 * 60
        }

        return joinable.sorted { lhs, rhs in
            if lhs.startDate != rhs.startDate { return lhs.startDate < rhs.startDate }
            return lhs.id < rhs.id
        }
    }
}

