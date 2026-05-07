import Foundation
import XCTest
@testable import OWAWidget

final class MenuBarStatusFormatterTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    func testShowsNowWithRemainingMinutesForSingleActiveMeeting() {
        let now = makeDate(hour: 10, minute: 0)
        let active = makeEvent(startHour: 9, startMinute: 55, endHour: 10, endMinute: 18)

        let label = MenuBarStatusFormatter.label(events: [active], now: now, calendar: calendar)

        XCTAssertEqual(label, "Now 18m")
    }

    func testPresentationMarksSingleActiveMeetingAsNow() {
        let now = makeDate(hour: 10, minute: 0)
        let active = makeEvent(startHour: 9, startMinute: 55, endHour: 10, endMinute: 18)

        let presentation = MenuBarStatusFormatter.presentation(events: [active], now: now, calendar: calendar)

        XCTAssertEqual(presentation.kind, .now)
        XCTAssertEqual(presentation.text, "Now 18m")
    }

    func testShowsNowCountForMultipleActiveMeetings() {
        let now = makeDate(hour: 10, minute: 0)
        let first = makeEvent(startHour: 9, startMinute: 0, endHour: 10, endMinute: 20, id: "a")
        let second = makeEvent(startHour: 9, startMinute: 30, endHour: 10, endMinute: 45, id: "b")

        let label = MenuBarStatusFormatter.label(events: [first, second], now: now, calendar: calendar)

        XCTAssertEqual(label, "Now x2")
    }

    func testPresentationMarksMultipleActiveMeetingsAsOverlappingNow() {
        let now = makeDate(hour: 10, minute: 0)
        let first = makeEvent(startHour: 9, startMinute: 0, endHour: 10, endMinute: 20, id: "a")
        let second = makeEvent(startHour: 9, startMinute: 30, endHour: 10, endMinute: 45, id: "b")

        let presentation = MenuBarStatusFormatter.presentation(events: [first, second], now: now, calendar: calendar)

        XCTAssertEqual(presentation.kind, .overlappingNow)
        XCTAssertEqual(presentation.text, "Now x2")
    }

    func testShowsNextWhenUpcomingMeetingStartsInFifteenMinutesOrLess() {
        let now = makeDate(hour: 10, minute: 0)
        let upcoming = makeEvent(startHour: 10, startMinute: 7, endHour: 10, endMinute: 40)

        let label = MenuBarStatusFormatter.label(events: [upcoming], now: now, calendar: calendar)

        XCTAssertEqual(label, "Next 7m")
    }

    func testPresentationMarksSoonMeetingAsNext() {
        let now = makeDate(hour: 10, minute: 0)
        let upcoming = makeEvent(startHour: 10, startMinute: 7, endHour: 10, endMinute: 40)

        let presentation = MenuBarStatusFormatter.presentation(events: [upcoming], now: now, calendar: calendar)

        XCTAssertEqual(presentation.kind, .next)
        XCTAssertEqual(presentation.text, "Next 7m")
    }

    func testShowsNextForExactlyFifteenMinutesBoundary() {
        let now = makeDate(hour: 10, minute: 0)
        let upcoming = makeEvent(startHour: 10, startMinute: 15, endHour: 10, endMinute: 45)

        let label = MenuBarStatusFormatter.label(events: [upcoming], now: now, calendar: calendar)

        XCTAssertEqual(label, "Next 15m")
    }

    func testShowsFreeMinutesWhenNextMeetingIsMoreThanFifteenMinutesAway() {
        let now = makeDate(hour: 10, minute: 0)
        let upcoming = makeEvent(startHour: 10, startMinute: 35, endHour: 11, endMinute: 0)

        let label = MenuBarStatusFormatter.label(events: [upcoming], now: now, calendar: calendar)

        XCTAssertEqual(label, "Free 35m")
    }

    func testShowsFreeHoursForExactlySixtyMinutesBoundary() {
        let now = makeDate(hour: 10, minute: 0)
        let upcoming = makeEvent(startHour: 11, startMinute: 0, endHour: 11, endMinute: 30)

        let label = MenuBarStatusFormatter.label(events: [upcoming], now: now, calendar: calendar)

        XCTAssertEqual(label, "Free 1h")
    }

    func testShowsFreeWhenNoMoreMeetingsTodayEvenIfTomorrowHasMeeting() {
        let now = makeDate(hour: 20, minute: 0)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now)!
        let tomorrowMeetingStart = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow)!
        let tomorrowMeetingEnd = calendar.date(bySettingHour: 9, minute: 30, second: 0, of: tomorrow)!
        let tomorrowMeeting = CalendarEvent(
            id: "tomorrow",
            title: "Tomorrow",
            startDate: tomorrowMeetingStart,
            endDate: tomorrowMeetingEnd,
            location: nil,
            bodyPreview: nil,
            joinURL: nil,
            platform: .generic,
            isAllDay: false,
            organizer: nil,
            attendees: [],
            accountID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        )

        let label = MenuBarStatusFormatter.label(events: [tomorrowMeeting], now: now, calendar: calendar)

        XCTAssertEqual(label, "Free")
    }

    func testPresentationMarksNoMeetingTodayAsFree() {
        let now = makeDate(hour: 20, minute: 0)
        let presentation = MenuBarStatusFormatter.presentation(events: [], now: now, calendar: calendar)

        XCTAssertEqual(presentation.kind, .free)
        XCTAssertEqual(presentation.text, "Free")
    }

    func testIgnoresAllDayEventsInStatusCalculations() {
        let now = makeDate(hour: 10, minute: 0)
        let allDay = CalendarEvent(
            id: "all-day",
            title: "All day",
            startDate: makeDate(hour: 0, minute: 0),
            endDate: makeDate(hour: 23, minute: 59),
            location: nil,
            bodyPreview: nil,
            joinURL: nil,
            platform: .generic,
            isAllDay: true,
            organizer: nil,
            attendees: [],
            accountID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        )
        let upcoming = makeEvent(startHour: 10, startMinute: 10, endHour: 10, endMinute: 40, id: "next")

        let label = MenuBarStatusFormatter.label(events: [allDay, upcoming], now: now, calendar: calendar)

        XCTAssertEqual(label, "Next 10m")
    }

    private func makeDate(hour: Int, minute: Int) -> Date {
        let reference = Date(timeIntervalSince1970: 1_699_920_000) // 2023-11-14 00:00:00 UTC
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: reference)!
    }

    private func makeEvent(
        startHour: Int,
        startMinute: Int,
        endHour: Int,
        endMinute: Int,
        id: String = "event"
    ) -> CalendarEvent {
        CalendarEvent(
            id: id,
            title: "Test",
            startDate: makeDate(hour: startHour, minute: startMinute),
            endDate: makeDate(hour: endHour, minute: endMinute),
            location: nil,
            bodyPreview: nil,
            joinURL: nil,
            platform: .generic,
            isAllDay: false,
            organizer: nil,
            attendees: [],
            accountID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        )
    }
}
