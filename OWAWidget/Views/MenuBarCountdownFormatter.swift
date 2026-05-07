import Foundation

enum MenuBarCountdownFormatter {
    static func label(
        eventStartDate: Date,
        now: Date,
        shortTimeFormatter: (Date) -> String
    ) -> String? {
        let interval = eventStartDate.timeIntervalSince(now)
        guard interval > 0 else { return nil }

        let minuteBoundary = 60.0
        let hourBoundary = 3600.0

        if interval < hourBoundary {
            let minutes = Int(ceil(interval / minuteBoundary))
            return "\(minutes)m"
        }

        return shortTimeFormatter(eventStartDate)
    }
}
