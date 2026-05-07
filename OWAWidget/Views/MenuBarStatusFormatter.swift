import Foundation

enum MenuBarStatusFormatter {
    enum Kind: Equatable {
        case free
        case next
        case now
        case overlappingNow
    }

    struct Presentation: Equatable {
        let text: String
        let kind: Kind
    }

    static func presentation(
        events: [CalendarEvent],
        now: Date,
        calendar: Calendar = .current
    ) -> Presentation {
        let relevantEvents = events.filter { !$0.isAllDay }
        let activeEvents = relevantEvents.filter { $0.startDate <= now && $0.endDate > now }

        if activeEvents.count > 1 {
            return Presentation(text: "Now x\(activeEvents.count)", kind: .overlappingNow)
        }

        if let activeEvent = activeEvents.first {
            let remainingMinutes = roundedUpMinutes(from: now, to: activeEvent.endDate)
            return Presentation(text: "Now \(remainingMinutes)m", kind: .now)
        }

        let nextTodayEvent = relevantEvents
            .filter { $0.startDate > now && calendar.isDate($0.startDate, inSameDayAs: now) }
            .sorted { $0.startDate < $1.startDate }
            .first

        guard let nextTodayEvent else {
            return Presentation(text: "Free", kind: .free)
        }

        let minutesUntilStart = roundedUpMinutes(from: now, to: nextTodayEvent.startDate)
        if minutesUntilStart <= 15 {
            return Presentation(text: "Next \(minutesUntilStart)m", kind: .next)
        }

        return Presentation(text: "Free \(freeValueLabel(minutes: minutesUntilStart))", kind: .free)
    }

    static func label(
        events: [CalendarEvent],
        now: Date,
        calendar: Calendar = .current
    ) -> String {
        presentation(events: events, now: now, calendar: calendar).text
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
