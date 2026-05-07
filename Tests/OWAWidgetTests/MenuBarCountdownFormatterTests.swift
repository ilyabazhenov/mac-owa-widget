import Foundation
import XCTest
@testable import OWAWidget

final class MenuBarCountdownFormatterTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    func testReturnsNilForPastEvent() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let eventStartDate = now.addingTimeInterval(-1)

        let label = MenuBarCountdownFormatter.label(
            eventStartDate: eventStartDate,
            now: now,
            shortTimeFormatter: { _ in "10:00" },
            calendar: calendar
        )

        XCTAssertNil(label)
    }

    func testReturnsNilForEventStartingNow() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

        let label = MenuBarCountdownFormatter.label(
            eventStartDate: now,
            now: now,
            shortTimeFormatter: { _ in "10:00" },
            calendar: calendar
        )

        XCTAssertNil(label)
    }

    func testRoundsUpUnderOneMinuteToOneMinute() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let eventStartDate = now.addingTimeInterval(59)

        let label = MenuBarCountdownFormatter.label(
            eventStartDate: eventStartDate,
            now: now,
            shortTimeFormatter: { _ in "10:00" },
            calendar: calendar
        )

        XCTAssertEqual(label, " 1m")
    }

    func testRoundsUpOneMinuteAndOneSecondToTwoMinutes() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let eventStartDate = now.addingTimeInterval(61)

        let label = MenuBarCountdownFormatter.label(
            eventStartDate: eventStartDate,
            now: now,
            shortTimeFormatter: { _ in "10:00" },
            calendar: calendar
        )

        XCTAssertEqual(label, " 2m")
    }

    func testReturnsMinuteLabelForUnderOneHour() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let eventStartDate = now.addingTimeInterval(3_599)

        let label = MenuBarCountdownFormatter.label(
            eventStartDate: eventStartDate,
            now: now,
            shortTimeFormatter: { _ in "10:00" },
            calendar: calendar
        )

        XCTAssertEqual(label, "60m")
    }

    func testTwoDigitMinutesHaveNoLeadingSpace() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let eventStartDate = now.addingTimeInterval(35 * 60)

        let label = MenuBarCountdownFormatter.label(
            eventStartDate: eventStartDate,
            now: now,
            shortTimeFormatter: { _ in "10:00" },
            calendar: calendar
        )

        XCTAssertEqual(label, "35m")
    }

    func testUsesHourLabelForOneHourOrMoreToday() {
        let now = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14 22:13:20 UTC
        let eventStartDate = now.addingTimeInterval(3_600)

        let label = MenuBarCountdownFormatter.label(
            eventStartDate: eventStartDate,
            now: now,
            shortTimeFormatter: { _ in "12:30" },
            calendar: calendar
        )

        XCTAssertEqual(label, " 1h")
    }

    func testRoundsUpOneHourAndOneSecondToTwoHoursToday() {
        let now = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14 22:13:20 UTC
        let eventStartDate = now.addingTimeInterval(3_601)

        let label = MenuBarCountdownFormatter.label(
            eventStartDate: eventStartDate,
            now: now,
            shortTimeFormatter: { _ in "12:30" },
            calendar: calendar
        )

        XCTAssertEqual(label, " 2h")
    }

    func testTwoDigitHoursHaveNoLeadingSpace() {
        let now = Date(timeIntervalSince1970: 1_699_920_000) // 2023-11-14 00:00:00 UTC
        let eventStartDate = now.addingTimeInterval(23 * 3_600) // 2023-11-14 23:00:00 UTC (same day)

        let label = MenuBarCountdownFormatter.label(
            eventStartDate: eventStartDate,
            now: now,
            shortTimeFormatter: { _ in "12:30" },
            calendar: calendar
        )

        XCTAssertEqual(label, "23h")
    }

    func testUsesShortTimeForTomorrowEvent() {
        let now = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14 22:13:20 UTC
        let tomorrowMorning = calendar.date(
            bySettingHour: 9,
            minute: 30,
            second: 0,
            of: calendar.date(byAdding: .day, value: 1, to: now)!
        )!

        let label = MenuBarCountdownFormatter.label(
            eventStartDate: tomorrowMorning,
            now: now,
            shortTimeFormatter: { _ in "09:30" },
            calendar: calendar
        )

        XCTAssertEqual(label, "09:30")
    }

    func testUsesShortTimeForTomorrowEvenIfLessThanOneHourAway() {
        let now = calendar.date(
            bySettingHour: 23,
            minute: 50,
            second: 0,
            of: Date(timeIntervalSince1970: 1_700_000_000)
        )!
        let eventStartDate = calendar.date(byAdding: .minute, value: 20, to: now)! // 00:10 next day

        let label = MenuBarCountdownFormatter.label(
            eventStartDate: eventStartDate,
            now: now,
            shortTimeFormatter: { _ in "00:10" },
            calendar: calendar
        )

        XCTAssertEqual(label, "00:10")
    }

    func testUsesShortTimeForExactlyTwentyFourHoursTomorrow() {
        let now = calendar.date(
            bySettingHour: 9,
            minute: 0,
            second: 0,
            of: Date(timeIntervalSince1970: 1_700_000_000)
        )!
        let eventStartDate = calendar.date(byAdding: .day, value: 1, to: now)!

        let label = MenuBarCountdownFormatter.label(
            eventStartDate: eventStartDate,
            now: now,
            shortTimeFormatter: { _ in "09:00" },
            calendar: calendar
        )

        XCTAssertEqual(label, "09:00")
    }

    func testNoMoreMeetingsTodayNextMeetingTomorrowShowsShortTime() {
        let now = calendar.date(
            bySettingHour: 18, minute: 0, second: 0,
            of: Date(timeIntervalSince1970: 1_700_000_000)
        )!
        let tomorrowMeeting = calendar.date(
            bySettingHour: 10, minute: 0, second: 0,
            of: calendar.date(byAdding: .day, value: 1, to: now)!
        )!

        let label = MenuBarCountdownFormatter.label(
            eventStartDate: tomorrowMeeting,
            now: now,
            shortTimeFormatter: { _ in "10:00" },
            calendar: calendar
        )

        XCTAssertEqual(label, "10:00")
    }

    func testTodayLateEveningEventShowsHoursNotTime() {
        // встреча сегодня в 23:30, сейчас 20:00 — должны быть часы, не время
        let now = calendar.date(
            bySettingHour: 20, minute: 0, second: 0,
            of: Date(timeIntervalSince1970: 1_699_920_000) // 2023-11-14
        )!
        let todayLateEvent = calendar.date(
            bySettingHour: 23, minute: 30, second: 0,
            of: now
        )!

        let label = MenuBarCountdownFormatter.label(
            eventStartDate: todayLateEvent,
            now: now,
            shortTimeFormatter: { _ in "must not be called" },
            calendar: calendar
        )

        XCTAssertEqual(label, " 4h")
    }

    func testShortTimeFormatterReceivesEventStartDate() {
        // форматтер должен получать дату встречи, а не текущее время
        let now = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14 22:13:20 UTC
        let tomorrowMeeting = calendar.date(
            bySettingHour: 9, minute: 30, second: 0,
            of: calendar.date(byAdding: .day, value: 1, to: now)!
        )!

        var capturedDate: Date?
        _ = MenuBarCountdownFormatter.label(
            eventStartDate: tomorrowMeeting,
            now: now,
            shortTimeFormatter: { date in
                capturedDate = date
                return "09:30"
            },
            calendar: calendar
        )

        XCTAssertEqual(capturedDate, tomorrowMeeting)
    }

    func testUsesHourLabelForEventAfterTomorrow() {
        let now = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14 22:13:20 UTC
        let eventStartDate = calendar.date(byAdding: .day, value: 2, to: now)!

        let label = MenuBarCountdownFormatter.label(
            eventStartDate: eventStartDate,
            now: now,
            shortTimeFormatter: { _ in "10:00" },
            calendar: calendar
        )

        XCTAssertEqual(label, "48h")
    }
}
