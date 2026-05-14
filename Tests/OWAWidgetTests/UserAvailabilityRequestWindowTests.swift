import XCTest
@testable import OWAWidget

final class UserAvailabilityRequestWindowTests: XCTestCase {

    private var moscow: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Moscow")!
        return cal
    }

    private func moscowDate(year: Int, month: Int, day: Int, hour: Int, minute: Int) -> Date {
        moscow.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func assertEqualDates(_ a: Date, _ b: Date, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThanOrEqual(abs(a.timeIntervalSince(b)), 1.0, file: file, line: line)
    }

    func testRequestStartIsMinimumOfTodayStartAndRangeStartDay() {
        let ref = moscowDate(year: 2025, month: 5, day: 14, hour: 15, minute: 0)
        let nextWeek = MeetingSearchRange.nextWeek.dateInterval(referenceNow: ref)
        let (start, _) = UserAvailabilityRequestWindow.bounds(
            for: nextWeek,
            referenceNow: ref,
            calendar: AppTimeZone.calendar
        )
        let todayStart = moscowDate(year: 2025, month: 5, day: 14, hour: 0, minute: 0)
        assertEqualDates(start, todayStart)
    }

    func testExclusiveEndExtendsAtLeastFifteenDaysPastTodayWhenRangeIsShort() {
        let ref = moscowDate(year: 2025, month: 5, day: 14, hour: 10, minute: 0)
        let tomorrow = MeetingSearchRange.tomorrow.dateInterval(referenceNow: ref)
        let (_, exclusiveEnd) = UserAvailabilityRequestWindow.bounds(
            for: tomorrow,
            referenceNow: ref,
            calendar: AppTimeZone.calendar
        )
        let todayStart = moscowDate(year: 2025, month: 5, day: 14, hour: 0, minute: 0)
        let expectedMin = moscow.date(byAdding: .day, value: 15, to: todayStart)!
        assertEqualDates(exclusiveEnd, expectedMin)
    }

    func testRequestStartUsesRangeStartDayWhenEarlierThanToday() {
        let ref = moscowDate(year: 2025, month: 5, day: 14, hour: 10, minute: 0)
        let start = moscowDate(year: 2025, month: 5, day: 12, hour: 9, minute: 0)
        let end = moscowDate(year: 2025, month: 5, day: 13, hour: 18, minute: 0)
        let range = DateInterval(start: start, end: end)
        let (requestStart, _) = UserAvailabilityRequestWindow.bounds(
            for: range,
            referenceNow: ref,
            calendar: AppTimeZone.calendar
        )
        let rangeStartDay = moscowDate(year: 2025, month: 5, day: 12, hour: 0, minute: 0)
        assertEqualDates(requestStart, rangeStartDay)
    }

    func testExclusiveEndUsesDayAfterRangeEndWhenRangeExtendsBeyondMinimumHorizon() {
        let ref = moscowDate(year: 2025, month: 5, day: 14, hour: 10, minute: 0)
        let start = moscowDate(year: 2025, month: 6, day: 2, hour: 0, minute: 0)
        let end = moscowDate(year: 2025, month: 6, day: 6, hour: 18, minute: 0)
        let range = DateInterval(start: start, end: end)
        let (_, exclusiveEnd) = UserAvailabilityRequestWindow.bounds(
            for: range,
            referenceNow: ref,
            calendar: AppTimeZone.calendar
        )
        let endDay = moscowDate(year: 2025, month: 6, day: 6, hour: 0, minute: 0)
        let expected = moscow.date(byAdding: .day, value: 1, to: endDay)!
        assertEqualDates(exclusiveEnd, expected)
    }
}
