import Foundation

enum MenuBarCountdownFormatter {
    static func label(
        eventStartDate: Date,
        now: Date,
        shortTimeFormatter: (Date) -> String,
        calendar: Calendar = .current,
        units: MenuBarUnits = .english
    ) -> String? {
        let interval = eventStartDate.timeIntervalSince(now)
        guard interval > 0 else { return nil }

        let minuteBoundary = 60.0
        let hourBoundary = 3600.0
        let dayBoundary = 24 * hourBoundary

        if calendar.isDate(eventStartDate, inSameDayAs: now) {
            if interval < hourBoundary {
                let minutes = Int(ceil(interval / minuteBoundary))
                return units.minutes(minutes, padded: true)
            }
            let hours = Int(ceil(interval / hourBoundary))
            return units.hours(hours, padded: true)
        }

        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(eventStartDate, inSameDayAs: tomorrow) {
            return shortTimeFormatter(eventStartDate)
        }

        if interval < hourBoundary {
            let minutes = Int(ceil(interval / minuteBoundary))
            return units.minutes(minutes, padded: true)
        }

        if interval >= dayBoundary {
            let days = Int(ceil(interval / dayBoundary))
            return units.days(days, padded: true)
        }

        let hours = Int(ceil(interval / hourBoundary))
        return units.hours(hours, padded: true)
    }
}
