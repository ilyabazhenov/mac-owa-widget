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

    func testTodayRangeClampsStartWhenAfterWorkdayEnd() {
        let ref = moscowDate(year: 2025, month: 5, day: 14, hour: 19, minute: 0)
        let interval = MeetingSearchRange.today.dateInterval(referenceNow: ref)
        let dayEnd = moscowDate(year: 2025, month: 5, day: 14, hour: 18, minute: 0)
        assertEqualDates(interval.end, dayEnd)
        assertEqualDates(interval.start, dayEnd)
        XCTAssertLessThanOrEqual(interval.start.timeIntervalSince(interval.end), 0)
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

    func testNextWeekSearchRangeMatchesSlotGridWorkweek() {
        let ref = moscowDate(year: 2025, month: 5, day: 14, hour: 12, minute: 0)
        let interval = MeetingSearchRange.nextWeek.dateInterval(referenceNow: ref)
        let week = MeetingSearchRange.nextWeek.slotGridWeekInterval(referenceNow: ref)
        let cols = week.weekdayColumnStartDates(calendar: AppTimeZone.calendar)
        XCTAssertEqual(cols.count, 5)
        assertEqualDates(interval.start, cols[0])
        let friday = cols[4]
        let expectedEnd = AppTimeZone.calendar.date(bySettingHour: 18, minute: 0, second: 0, of: friday)!
        assertEqualDates(interval.end, expectedEnd)
    }

    func testNextWeekSlotGridIsFollowingCalendarWeek() {
        let ref = moscowDate(year: 2025, month: 5, day: 14, hour: 12, minute: 0)
        let week = MeetingSearchRange.nextWeek.slotGridWeekInterval(referenceNow: ref)
        let cols = week.weekdayColumnStartDates(calendar: AppTimeZone.calendar)
        XCTAssertEqual(cols.count, 5)
        let first = moscowDate(year: 2025, month: 5, day: 19, hour: 0, minute: 0)
        assertEqualDates(cols[0], first)
    }

    func testTomorrowSlotGridShowsFullWorkweek() {
        let ref = moscowDate(year: 2025, month: 5, day: 14, hour: 9, minute: 0)
        let week = MeetingSearchRange.tomorrow.slotGridWeekInterval(referenceNow: ref)
        let cols = week.weekdayColumnStartDates(calendar: AppTimeZone.calendar)
        XCTAssertEqual(cols.count, 5)
    }

    func testThisWeekSlotGridStartsOnMonday() {
        let ref = moscowDate(year: 2025, month: 5, day: 14, hour: 10, minute: 0)
        let week = MeetingSearchRange.thisWeek.slotGridWeekInterval(referenceNow: ref)
        let cols = week.weekdayColumnStartDates(calendar: AppTimeZone.calendar)
        XCTAssertEqual(cols.count, 5)
        let mon = moscowDate(year: 2025, month: 5, day: 12, hour: 0, minute: 0)
        assertEqualDates(cols[0], mon)
    }

    func testWeekendOnlyIntervalYieldsNoColumns() {
        let cal = AppTimeZone.calendar
        let sat = moscowDate(year: 2025, month: 5, day: 17, hour: 0, minute: 0)
        let sunEnd = moscowDate(year: 2025, month: 5, day: 18, hour: 12, minute: 0)
        let interval = DateInterval(start: sat, end: sunEnd)
        let cols = interval.weekdayColumnStartDates(calendar: cal)
        XCTAssertTrue(cols.isEmpty)
    }
}
