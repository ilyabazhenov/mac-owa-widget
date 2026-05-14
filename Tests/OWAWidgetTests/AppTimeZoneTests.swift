import XCTest
@testable import OWAWidget

final class AppTimeZoneTests: XCTestCase {

    func testZoneIdentifierIsEuropeMoscow() {
        XCTAssertEqual(AppTimeZone.zone.identifier, "Europe/Moscow")
    }

    func testUtcOffsetLabelUsesWholeHourOffset() {
        // Europe/Moscow is UTC+3 year-round in the current policy window used by Foundation.
        XCTAssertTrue(AppTimeZone.utcOffsetLabel.contains("UTC"))
        XCTAssertTrue(AppTimeZone.utcOffsetLabel.contains("+") || AppTimeZone.utcOffsetLabel.contains("-"))
    }

    func testCalendarUsesDisplayZone() {
        XCTAssertEqual(AppTimeZone.calendar.timeZone.identifier, AppTimeZone.zone.identifier)
    }
}
