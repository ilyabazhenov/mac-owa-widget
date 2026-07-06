import Foundation

enum MenuBarLabelFormatter {
    struct Presentation: Equatable {
        let text: String
        let statusKind: MenuBarStatusFormatter.Kind?
    }

    static func presentation(
        mode: MenuBarDisplayMode,
        events: [CalendarEvent],
        now: Date,
        shortTimeFormatter: (Date) -> String,
        calendar: Calendar = .current
    ) -> Presentation? {
        switch mode {
        case .countdown:
            guard let event = events
                .filter({ !$0.isAllDay && $0.startDate > now })
                .sorted(by: { $0.startDate < $1.startDate })
                .first
            else { return nil }
            guard let text = MenuBarCountdownFormatter.label(
                eventStartDate: event.startDate,
                now: now,
                shortTimeFormatter: shortTimeFormatter,
                calendar: calendar
            )
            else { return nil }
            return Presentation(text: text, statusKind: nil)
        case .status:
            let status = MenuBarStatusFormatter.presentation(events: events, now: now, calendar: calendar)
            return Presentation(text: status.text, statusKind: status.kind)
        case .smart:
            // Smart mode also drives icon + pulse + tooltip, so `MenuBarLabelView` computes it
            // directly from `MenuBarSmartStatusFormatter` rather than via this text-only path.
            return nil
        }
    }

    static func label(
        mode: MenuBarDisplayMode,
        events: [CalendarEvent],
        now: Date,
        shortTimeFormatter: (Date) -> String,
        calendar: Calendar = .current
    ) -> String? {
        presentation(
            mode: mode,
            events: events,
            now: now,
            shortTimeFormatter: shortTimeFormatter,
            calendar: calendar
        )?.text
    }
}
