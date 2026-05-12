import Foundation

enum MenuBarCountdownFormatter {
    static func label(
        eventStartDate: Date,
        now: Date,
        shortTimeFormatter: (Date) -> String,
        calendar: Calendar = .current
    ) -> String? {
        let interval = eventStartDate.timeIntervalSince(now)
        guard interval > 0 else { return nil }

        let minuteBoundary = 60.0
        let hourBoundary = 3600.0
        let dayBoundary = 24 * hourBoundary

        if calendar.isDate(eventStartDate, inSameDayAs: now) {
            if interval < hourBoundary {
                let minutes = Int(ceil(interval / minuteBoundary))
                return String(format: "%2d", minutes) + "m"
            }
            let hours = Int(ceil(interval / hourBoundary))
            return String(format: "%2d", hours) + "h"
        }

        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(eventStartDate, inSameDayAs: tomorrow) {
            return shortTimeFormatter(eventStartDate)
        }

        if interval < hourBoundary {
            let minutes = Int(ceil(interval / minuteBoundary))
            return String(format: "%2d", minutes) + "m"
        }

        if interval >= dayBoundary {
            let days = Int(ceil(interval / dayBoundary))
            return String(format: "%2d", days) + "d"
        }

        let hours = Int(ceil(interval / hourBoundary))
        return String(format: "%2d", hours) + "h"
    }
}
