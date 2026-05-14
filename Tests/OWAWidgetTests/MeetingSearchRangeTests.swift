import XCTest
@testable import OWAWidget

final class MeetingSearchRangeTests: XCTestCase {

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

    func testTodayRangeStartsAtReferenceNowWhenAfterMidnight() {
        let ref = moscowDate(year: 2025, month: 5, day: 14, hour: 11, minute: 30)
        let interval = MeetingSearchRange.today.dateInterval(referenceNow: ref)
        let dayStart = moscowDate(year: 2025, month: 5, day: 14, hour: 0, minute: 0)
        let dayEnd = moscowDate(year: 2025, month: 5, day: 14, hour: 18, minute: 0)
        assertEqualDates(interval.start, ref)
        assertEqualDates(interval.end, dayEnd)
        XCTAssertGreaterThanOrEqual(interval.start.timeIntervalSince(dayStart), 0)
    }

    func testTomorrowRangeIsNextCalendarDay() {
        let ref = moscowDate(year: 2025, month: 5, day: 14, hour: 9, minute: 0)
        let interval = MeetingSearchRange.tomorrow.dateInterval(referenceNow: ref)
        let expectedStart = moscowDate(year: 2025, month: 5, day: 15, hour: 0, minute: 0)
        let expectedEnd = moscowDate(year: 2025, month: 5, day: 15, hour: 18, minute: 0)
        assertEqualDates(interval.start, expectedStart)
        assertEqualDates(interval.end, expectedEnd)
    }

    func testThisWeekEndUsesFifthDayFromTodayStart() {
        let ref = moscowDate(year: 2025, month: 5, day: 14, hour: 10, minute: 0)
        let interval = MeetingSearchRange.thisWeek.dateInterval(referenceNow: ref)
        let todayStart = moscowDate(year: 2025, month: 5, day: 14, hour: 0, minute: 0)
        let endDay = moscow.date(byAdding: .day, value: 5, to: todayStart)!
        let expectedEnd = moscow.date(bySettingHour: 18, minute: 0, second: 0, of: endDay)!
        assertEqualDates(interval.start, ref)
        assertEqualDates(interval.end, expectedEnd)
    }

    func testNextWeekSpansSevenDaysOut() {
        let ref = moscowDate(year: 2025, month: 5, day: 14, hour: 12, minute: 0)
        let interval = MeetingSearchRange.nextWeek.dateInterval(referenceNow: ref)
        let todayStart = moscowDate(year: 2025, month: 5, day: 14, hour: 0, minute: 0)
        let expectedStart = moscow.date(byAdding: .day, value: 7, to: todayStart)!
        let endAnchor = moscow.date(byAdding: .day, value: 12, to: todayStart)!
        let expectedEnd = moscow.date(bySettingHour: 18, minute: 0, second: 0, of: endAnchor)!
        assertEqualDates(interval.start, expectedStart)
        assertEqualDates(interval.end, expectedEnd)
    }
}
