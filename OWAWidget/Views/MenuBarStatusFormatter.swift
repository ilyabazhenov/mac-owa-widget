import Foundation

enum MenuBarStatusFormatter {
    static func label(
        events: [CalendarEvent],
        now: Date,
        calendar: Calendar = .current
    ) -> String {
        let relevantEvents = events.filter { !$0.isAllDay }
        let activeEvents = relevantEvents.filter { $0.startDate <= now && $0.endDate > now }

        if activeEvents.count > 1 {
            return "Now x\(activeEvents.count)"
        }

        if let activeEvent = activeEvents.first {
            let remainingMinutes = roundedUpMinutes(from: now, to: activeEvent.endDate)
            return "Now \(remainingMinutes)m"
        }

        let nextTodayEvent = relevantEvents
            .filter { $0.startDate > now && calendar.isDate($0.startDate, inSameDayAs: now) }
            .sorted { $0.startDate < $1.startDate }
            .first

        guard let nextTodayEvent else {
            return "Free"
        }

        let minutesUntilStart = roundedUpMinutes(from: now, to: nextTodayEvent.startDate)
        if minutesUntilStart <= 15 {
            return "Next \(minutesUntilStart)m"
        }

        return "Free \(freeValueLabel(minutes: minutesUntilStart))"
    }

    private static func roundedUpMinutes(from now: Date, to target: Date) -> Int {
        let delta = target.timeIntervalSince(now)
        let minutes = Int(ceil(delta / 60))
        return max(0, minutes)
    }

    private static func freeValueLabel(minutes: Int) -> String {
        if minutes < 60 {
            return "\(minutes)m"
        }

        let hours = Int(ceil(Double(minutes) / 60))
        return "\(hours)h"
    }
}
