import Foundation
import XCTest
@testable import OWAWidget

final class MenuBarSmartStatusFormatterTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    // MARK: - Engaged: in meeting

    func testInMeetingShowsRemainingDurationAndPulses() {
        let now = makeDate(hour: 10, minute: 0)
        let active = makeEvent(startHour: 9, startMinute: 55, endHour: 10, endMinute: 18, join: true)

        let p = MenuBarSmartStatusFormatter.presentation(events: [active], now: now, calendar: calendar)

        XCTAssertEqual(p.category, .engaged)
        XCTAssertEqual(p.content, .duration("18m"))
        XCTAssertTrue(p.pulse)
        XCTAssertEqual(p.tooltip, .inMeeting(remainingMinutes: 18, hasJoinURL: true))
    }

    func testOverlappingMeetingsFoldIntoSoonestRemainingWithOverlapTooltip() {
        let now = makeDate(hour: 10, minute: 0)
        let first = makeEvent(startHour: 9, startMinute: 0, endHour: 10, endMinute: 20, id: "a")
        let second = makeEvent(startHour: 9, startMinute: 30, endHour: 10, endMinute: 45, id: "b")

        let p = MenuBarSmartStatusFormatter.presentation(events: [first, second], now: now, calendar: calendar)

        XCTAssertEqual(p.category, .engaged)
        XCTAssertEqual(p.content, .duration("20m")) // soonest-ending of the two
        XCTAssertTrue(p.pulse)
        XCTAssertEqual(p.tooltip, .overlap(count: 2))
    }

    // MARK: - Engaged: upcoming

    func testImminentMeetingPulsesWithJoinNowTooltip() {
        let now = makeDate(hour: 10, minute: 0)
        let upcoming = makeEvent(startHour: 10, startMinute: 2, endHour: 10, endMinute: 30, join: true)

        let p = MenuBarSmartStatusFormatter.presentation(events: [upcoming], now: now, calendar: calendar)

        XCTAssertEqual(p.category, .engaged)
        XCTAssertEqual(p.content, .duration("2m"))
        XCTAssertTrue(p.pulse)
        XCTAssertEqual(p.tooltip, .joinNow(hasJoinURL: true))
    }

    func testImminentWithoutJoinLinkStillEngagedButFlagsMissingLink() {
        let now = makeDate(hour: 10, minute: 0)
        let upcoming = makeEvent(startHour: 10, startMinute: 1, endHour: 10, endMinute: 30, join: false)

        let p = MenuBarSmartStatusFormatter.presentation(events: [upcoming], now: now, calendar: calendar)

        XCTAssertEqual(p.tooltip, .joinNow(hasJoinURL: false))
    }

    func testSoonMeetingUsesEngagedGlyphButDoesNotPulse() {
        let now = makeDate(hour: 10, minute: 0)
        let upcoming = makeEvent(startHour: 10, startMinute: 10, endHour: 10, endMinute: 40, join: true)

        let p = MenuBarSmartStatusFormatter.presentation(events: [upcoming], now: now, calendar: calendar)

        XCTAssertEqual(p.category, .engaged)
        XCTAssertEqual(p.content, .duration("10m"))
        XCTAssertFalse(p.pulse)
        XCTAssertEqual(p.tooltip, .soon(start: upcoming.startDate, hasJoinURL: true))
    }

    func testFifteenMinuteBoundaryIsStillSoon() {
        let now = makeDate(hour: 10, minute: 0)
        let upcoming = makeEvent(startHour: 10, startMinute: 15, endHour: 10, endMinute: 45)

        let p = MenuBarSmartStatusFormatter.presentation(events: [upcoming], now: now, calendar: calendar)

        XCTAssertEqual(p.category, .engaged)
        XCTAssertFalse(p.pulse)
    }

    // MARK: - Idle: shows the *time* of the next meeting

    func testFreeTodayShowsNextMeetingTimeNotDuration() {
        let now = makeDate(hour: 10, minute: 0)
        let upcoming = makeEvent(startHour: 14, startMinute: 0, endHour: 14, endMinute: 30)

        let p = MenuBarSmartStatusFormatter.presentation(events: [upcoming], now: now, calendar: calendar)

        XCTAssertEqual(p.category, .idle)
        XCTAssertEqual(p.content, .time(upcoming.startDate))
        XCTAssertFalse(p.pulse)
        XCTAssertEqual(p.tooltip, .freeUntil(start: upcoming.startDate))
    }

    func testDoneForTodayShowsTomorrowsMeetingTime() {
        let now = makeDate(hour: 20, minute: 0)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now)!
        let start = calendar.date(bySettingHour: 9, minute: 30, second: 0, of: tomorrow)!
        let end = calendar.date(bySettingHour: 9, minute: 45, second: 0, of: tomorrow)!
        let event = makeEvent(start: start, end: end, id: "tomorrow")

        let p = MenuBarSmartStatusFormatter.presentation(events: [event], now: now, calendar: calendar)

        XCTAssertEqual(p.category, .idle)
        XCTAssertEqual(p.content, .time(start))
        XCTAssertEqual(p.tooltip, .nextDay(start: start))
    }

    func testNothingUpcomingIsIconOnly() {
        let now = makeDate(hour: 20, minute: 0)

        let p = MenuBarSmartStatusFormatter.presentation(events: [], now: now, calendar: calendar)

        XCTAssertEqual(p.category, .idle)
        XCTAssertEqual(p.content, .iconOnly)
        XCTAssertFalse(p.pulse)
        XCTAssertEqual(p.tooltip, .nothingUpcoming)
    }

    func testCancelledInProgressMeetingIsIgnored() {
        let now = makeDate(hour: 10, minute: 30)
        let cancelledActive = makeEvent(startHour: 10, startMinute: 0, endHour: 11, endMinute: 0, cancelled: true)

        let p = MenuBarSmartStatusFormatter.presentation(events: [cancelledActive], now: now, calendar: calendar)

        XCTAssertEqual(p.category, .idle)
        XCTAssertEqual(p.content, .iconOnly)
        XCTAssertFalse(p.pulse)
        XCTAssertEqual(p.tooltip, .nothingUpcoming)
    }

    func testCancelledMeetingIsSkippedWhenPickingNext() {
        let now = makeDate(hour: 10, minute: 0)
        let cancelledSoon = makeEvent(startHour: 10, startMinute: 5, endHour: 10, endMinute: 30, id: "cancelled", cancelled: true)
        let realLater = makeEvent(startHour: 14, startMinute: 0, endHour: 14, endMinute: 30, id: "real")

        let p = MenuBarSmartStatusFormatter.presentation(events: [cancelledSoon, realLater], now: now, calendar: calendar)

        XCTAssertEqual(p.category, .idle)
        XCTAssertEqual(p.content, .time(realLater.startDate))
        XCTAssertEqual(p.tooltip, .freeUntil(start: realLater.startDate))
    }

    func testNextMeetingSeveralDaysOutShowsDayCountNotTomorrow() {
        let now = makeDate(hour: 12, minute: 0)
        let threeDaysOut = calendar.date(byAdding: .day, value: 3, to: now)!
        let start = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: threeDaysOut)!
        let end = calendar.date(bySettingHour: 9, minute: 30, second: 0, of: threeDaysOut)!
        let event = makeEvent(start: start, end: end, id: "later")

        let p = MenuBarSmartStatusFormatter.presentation(events: [event], now: now, calendar: calendar)

        XCTAssertEqual(p.category, .idle)
        XCTAssertEqual(p.content, .relativeDays(3))
        XCTAssertFalse(p.pulse)
        XCTAssertEqual(p.tooltip, .laterDays(count: 3))
    }

    func testAllDayEventsAreIgnored() {
        let now = makeDate(hour: 10, minute: 0)
        let allDay = makeEvent(start: makeDate(hour: 0, minute: 0), end: makeDate(hour: 23, minute: 59), id: "all-day", isAllDay: true)
        let upcoming = makeEvent(startHour: 10, startMinute: 10, endHour: 10, endMinute: 40, id: "next")

        let p = MenuBarSmartStatusFormatter.presentation(events: [allDay, upcoming], now: now, calendar: calendar)

        XCTAssertEqual(p.tooltip, .soon(start: upcoming.startDate, hasJoinURL: false))
    }

    // MARK: - Helpers

    private func makeDate(hour: Int, minute: Int) -> Date {
        let reference = Date(timeIntervalSince1970: 1_699_920_000) // 2023-11-14 00:00:00 UTC
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: reference)!
    }

    private func makeEvent(
        startHour: Int,
        startMinute: Int,
        endHour: Int,
        endMinute: Int,
        id: String = "event",
        join: Bool = false,
        cancelled: Bool = false
    ) -> CalendarEvent {
        makeEvent(
            start: makeDate(hour: startHour, minute: startMinute),
            end: makeDate(hour: endHour, minute: endMinute),
            id: id,
            join: join,
            cancelled: cancelled
        )
    }

    private func makeEvent(
        start: Date,
        end: Date,
        id: String = "event",
        join: Bool = false,
        isAllDay: Bool = false,
        cancelled: Bool = false
    ) -> CalendarEvent {
        CalendarEvent(
            id: id,
            title: "Test",
            startDate: start,
            endDate: end,
            location: nil,
            bodyPreview: nil,
            joinURL: join ? URL(string: "https://example.com/join") : nil,
            platform: .generic,
            isAllDay: isAllDay,
            organizer: nil,
            attendees: [],
            accountID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            isCancelled: cancelled
        )
    }
}
