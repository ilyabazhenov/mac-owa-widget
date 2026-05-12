import Foundation
import XCTest
@testable import OWAWidget

final class MenuBarLabelFormatterTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    func testCountdownModeUsesExistingCountdownFormatting() {
        let now = makeDate(dayOffset: 0, hour: 18, minute: 0)
        let tomorrowStart = makeDate(dayOffset: 1, hour: 9, minute: 30)
        let tomorrowEnd = makeDate(dayOffset: 1, hour: 10, minute: 0)
        let event = makeEvent(id: "tomorrow", start: tomorrowStart, end: tomorrowEnd)

        let label = MenuBarLabelFormatter.label(
            mode: .countdown,
            events: [event],
            now: now,
            shortTimeFormatter: { _ in "09:30" },
            calendar: calendar
        )

        XCTAssertEqual(label, "09:30")
    }

    func testStatusModeUsesStatusFormattingRules() {
        let now = makeDate(dayOffset: 0, hour: 10, minute: 0)
        let event = makeEvent(
            id: "today",
            start: makeDate(dayOffset: 0, hour: 10, minute: 7),
            end: makeDate(dayOffset: 0, hour: 10, minute: 40)
        )

        let label = MenuBarLabelFormatter.label(
            mode: .status,
            events: [event],
            now: now,
            shortTimeFormatter: { _ in "unused" },
            calendar: calendar
        )

        XCTAssertEqual(label, "Next 7m")
    }

    func testStatusPresentationIncludesSemanticStatusKind() {
        let now = makeDate(dayOffset: 0, hour: 10, minute: 0)
        let event = makeEvent(
            id: "today",
            start: makeDate(dayOffset: 0, hour: 10, minute: 7),
            end: makeDate(dayOffset: 0, hour: 10, minute: 40)
        )

        let presentation = MenuBarLabelFormatter.presentation(
            mode: .status,
            events: [event],
            now: now,
            shortTimeFormatter: { _ in "unused" },
            calendar: calendar
        )

        XCTAssertEqual(presentation?.text, "Next 7m")
        XCTAssertEqual(presentation?.statusKind, .next)
    }

    func testCountdownPresentationHasNoStatusKind() {
        let now = makeDate(dayOffset: 0, hour: 18, minute: 0)
        let tomorrowStart = makeDate(dayOffset: 1, hour: 9, minute: 30)
        let tomorrowEnd = makeDate(dayOffset: 1, hour: 10, minute: 0)
        let event = makeEvent(id: "tomorrow", start: tomorrowStart, end: tomorrowEnd)

        let presentation = MenuBarLabelFormatter.presentation(
            mode: .countdown,
            events: [event],
            now: now,
            shortTimeFormatter: { _ in "09:30" },
            calendar: calendar
        )

        XCTAssertEqual(presentation?.text, "09:30")
        XCTAssertNil(presentation?.statusKind)
    }

    func testCountdownModeIgnoresAllDayEvents() {
        let now = makeDate(dayOffset: 0, hour: 18, minute: 0)
        let tomorrowAllDay = makeEvent(
            id: "all-day",
            start: makeDate(dayOffset: 1, hour: 0, minute: 0),
            end: makeDate(dayOffset: 2, hour: 0, minute: 0),
            isAllDay: true
        )
        let tomorrowMeeting = makeEvent(
            id: "tomorrow-meeting",
            start: makeDate(dayOffset: 1, hour: 9, minute: 30),
            end: makeDate(dayOffset: 1, hour: 10, minute: 0),
            isAllDay: false
        )

        let label = MenuBarLabelFormatter.label(
            mode: .countdown,
            events: [tomorrowAllDay, tomorrowMeeting],
            now: now,
            shortTimeFormatter: { _ in "09:30" },
            calendar: calendar
        )

        XCTAssertEqual(label, "09:30")
    }

    func testCountdownModeReturnsNilWhenOnlyAllDayFutureEventsExist() {
        let now = makeDate(dayOffset: 0, hour: 18, minute: 0)
        let allDayOnly = makeEvent(
            id: "all-day-only",
            start: makeDate(dayOffset: 1, hour: 0, minute: 0),
            end: makeDate(dayOffset: 2, hour: 0, minute: 0),
            isAllDay: true
        )

        let label = MenuBarLabelFormatter.label(
            mode: .countdown,
            events: [allDayOnly],
            now: now,
            shortTimeFormatter: { _ in "unused" },
            calendar: calendar
        )

        XCTAssertNil(label)
    }

    func testCountdownModeReturnsNilWhenAllEventsAreInPast() {
        let now = makeDate(dayOffset: 0, hour: 18, minute: 0)
        let past = makeEvent(
            id: "past",
            start: makeDate(dayOffset: 0, hour: 9, minute: 0),
            end: makeDate(dayOffset: 0, hour: 9, minute: 30)
        )

        let label = MenuBarLabelFormatter.label(
            mode: .countdown,
            events: [past],
            now: now,
            shortTimeFormatter: { _ in "unused" },
            calendar: calendar
        )

        XCTAssertNil(label)
    }

    func testCountdownModeSelectsEarliestUpcomingNonAllDayFromUnsortedList() {
        let now = makeDate(dayOffset: 0, hour: 18, minute: 0)
        let later = makeEvent(
            id: "later",
            start: makeDate(dayOffset: 1, hour: 11, minute: 0),
            end: makeDate(dayOffset: 1, hour: 11, minute: 30)
        )
        let allDay = makeEvent(
            id: "all-day",
            start: makeDate(dayOffset: 1, hour: 0, minute: 0),
            end: makeDate(dayOffset: 2, hour: 0, minute: 0),
            isAllDay: true
        )
        let earliest = makeEvent(
            id: "earliest",
            start: makeDate(dayOffset: 1, hour: 9, minute: 30),
            end: makeDate(dayOffset: 1, hour: 10, minute: 0)
        )

        let label = MenuBarLabelFormatter.label(
            mode: .countdown,
            events: [later, allDay, earliest],
            now: now,
            shortTimeFormatter: { _ in "09:30" },
            calendar: calendar
        )

        XCTAssertEqual(label, "09:30")
    }

    private func makeDate(dayOffset: Int, hour: Int, minute: Int) -> Date {
        let reference = Date(timeIntervalSince1970: 1_699_920_000) // 2023-11-14 00:00:00 UTC
        let day = calendar.date(byAdding: .day, value: dayOffset, to: reference)!
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
    }

    private func makeEvent(id: String, start: Date, end: Date, isAllDay: Bool = false) -> CalendarEvent {
        CalendarEvent(
            id: id,
            title: "Test",
            startDate: start,
            endDate: end,
            location: nil,
            bodyPreview: nil,
            joinURL: nil,
            platform: .generic,
            isAllDay: isAllDay,
            organizer: nil,
            attendees: [],
            accountID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        )
    }
}
