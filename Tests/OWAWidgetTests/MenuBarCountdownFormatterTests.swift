import Foundation
import XCTest
@testable import OWAWidget

final class MenuBarCountdownFormatterTests: XCTestCase {
    func testReturnsNilForPastEvent() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let eventStartDate = now.addingTimeInterval(-1)

        let label = MenuBarCountdownFormatter.label(
            eventStartDate: eventStartDate,
            now: now,
            shortTimeFormatter: { _ in "10:00" }
        )

        XCTAssertNil(label)
    }

    func testReturnsNilForEventStartingNow() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

        let label = MenuBarCountdownFormatter.label(
            eventStartDate: now,
            now: now,
            shortTimeFormatter: { _ in "10:00" }
        )

        XCTAssertNil(label)
    }

    func testRoundsUpUnderOneMinuteToOneMinute() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let eventStartDate = now.addingTimeInterval(59)

        let label = MenuBarCountdownFormatter.label(
            eventStartDate: eventStartDate,
            now: now,
            shortTimeFormatter: { _ in "10:00" }
        )

        XCTAssertEqual(label, "1m")
    }

    func testRoundsUpOneMinuteAndOneSecondToTwoMinutes() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let eventStartDate = now.addingTimeInterval(61)

        let label = MenuBarCountdownFormatter.label(
            eventStartDate: eventStartDate,
            now: now,
            shortTimeFormatter: { _ in "10:00" }
        )

        XCTAssertEqual(label, "2m")
    }

    func testReturnsMinuteLabelForUnderOneHour() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let eventStartDate = now.addingTimeInterval(3_599)

        let label = MenuBarCountdownFormatter.label(
            eventStartDate: eventStartDate,
            now: now,
            shortTimeFormatter: { _ in "10:00" }
        )

        XCTAssertEqual(label, "60m")
    }

    func testUsesShortTimeFormatterForOneHourOrMore() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let eventStartDate = now.addingTimeInterval(3_600)

        let label = MenuBarCountdownFormatter.label(
            eventStartDate: eventStartDate,
            now: now,
            shortTimeFormatter: { _ in "12:30" }
        )

        XCTAssertEqual(label, "12:30")
    }
}
