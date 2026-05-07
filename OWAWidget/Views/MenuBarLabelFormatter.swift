import Foundation

enum MenuBarLabelFormatter {
    static func label(
        mode: MenuBarDisplayMode,
        events: [CalendarEvent],
        now: Date,
        shortTimeFormatter: (Date) -> String,
        calendar: Calendar = .current
    ) -> String? {
        switch mode {
        case .countdown:
            guard let event = events
                .filter({ $0.startDate > now })
                .sorted(by: { $0.startDate < $1.startDate })
                .first
            else { return nil }
            return MenuBarCountdownFormatter.label(
                eventStartDate: event.startDate,
                now: now,
                shortTimeFormatter: shortTimeFormatter,
                calendar: calendar
            )
        case .status:
            return MenuBarStatusFormatter.label(events: events, now: now, calendar: calendar)
        }
    }
}
