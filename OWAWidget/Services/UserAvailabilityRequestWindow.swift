import Foundation

/// Derives the GetUserAvailability request window used by `CalendarService.findFreeSlots`.
enum UserAvailabilityRequestWindow {
    /// - Parameters:
    ///   - range: Selected slot-search interval (same as passed to `MeetingFreeSlotCalculator`).
    ///   - referenceNow: Clock injection for tests; production passes `Date()`.
    ///   - calendar: Typically `AppTimeZone.calendar`.
    /// - Returns: `start` is inclusive (midnight-aligned); `exclusiveEnd` is the first instant **not** covered.
    static func bounds(for range: DateInterval, referenceNow: Date, calendar: Calendar) -> (start: Date, exclusiveEnd: Date) {
        let rangeStartDay = calendar.startOfDay(for: range.start)
        let todayStart = calendar.startOfDay(for: referenceNow)
        let requestStart = min(rangeStartDay, todayStart)

        let rangeBasedExclusiveEnd: Date = {
            let end = calendar.startOfDay(for: range.end)
            return calendar.date(byAdding: .day, value: 1, to: end) ?? range.end
        }()

        let fourteenDaysForwardExclusiveEnd =
            calendar.date(byAdding: .day, value: 15, to: todayStart) ?? rangeBasedExclusiveEnd
        let exclusiveEnd = max(rangeBasedExclusiveEnd, fourteenDaysForwardExclusiveEnd)

        return (requestStart, exclusiveEnd)
    }
}
