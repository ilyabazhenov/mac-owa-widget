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

    private func makeDate(dayOffset: Int, hour: Int, minute: Int) -> Date {
        let reference = Date(timeIntervalSince1970: 1_699_920_000) // 2023-11-14 00:00:00 UTC
        let day = calendar.date(byAdding: .day, value: dayOffset, to: reference)!
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
    }

    private func makeEvent(id: String, start: Date, end: Date) -> CalendarEvent {
        CalendarEvent(
            id: id,
            title: "Test",
            startDate: start,
            endDate: end,
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
