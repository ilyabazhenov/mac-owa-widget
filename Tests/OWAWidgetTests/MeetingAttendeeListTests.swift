import XCTest
@testable import OWAWidget

/// Covers the attendee-list presentation rules: organizer removal (by name match and by an explicit
/// `Organizer` response) and alphabetical sorting, while preserving each attendee's `kind`.
final class MeetingAttendeeListTests: XCTestCase {

    private func attendee(_ name: String, kind: EventAttendeeKind = .required, response: MeetingResponseType = .notResponded) -> EventAttendee {
        EventAttendee(name: name, email: nil, kind: kind, response: response)
    }

    func testRemovesOrganizerByNameMatch() {
        let input = [attendee("Петров Михаил"), attendee("Иванов Илья")]
        let result = MeetingAttendeeList.forDisplay(input, organizer: "  Петров Михаил ")
        XCTAssertEqual(result.map(\.name), ["Иванов Илья"])
    }

    func testRemovesOrganizerByResponseType() {
        let input = [attendee("Some Organizer", response: .organizer), attendee("Real Attendee")]
        let result = MeetingAttendeeList.forDisplay(input, organizer: nil)
        XCTAssertEqual(result.map(\.name), ["Real Attendee"])
    }

    func testSortsAlphabeticallyCaseInsensitively() {
        let input = [attendee("Яшина Оксана"), attendee("Абрамов Алексей"), attendee("иванов илья")]
        let result = MeetingAttendeeList.forDisplay(input, organizer: nil)
        XCTAssertEqual(result.map(\.name), ["Абрамов Алексей", "иванов илья", "Яшина Оксана"])
    }

    func testPreservesKindAfterFilteringAndSorting() {
        let input = [
            attendee("B required", kind: .required),
            attendee("A optional", kind: .optional),
        ]
        let result = MeetingAttendeeList.forDisplay(input, organizer: nil)
        XCTAssertEqual(result.map(\.name), ["A optional", "B required"])
        XCTAssertEqual(result.first?.kind, .optional)
        XCTAssertEqual(result.last?.kind, .required)
    }

    func testEmptyWhenOnlyOrganizerPresent() {
        let input = [attendee("Solo Organizer")]
        XCTAssertTrue(MeetingAttendeeList.forDisplay(input, organizer: "Solo Organizer").isEmpty)
    }

    /// A small invite shows its roster right away; a company-wide one starts folded so the
    /// agenda stays visible in the panel.
    func testAutoExpandsOnlySmallLists() {
        XCTAssertTrue(MeetingAttendeeList.autoExpands(count: 0))
        XCTAssertTrue(MeetingAttendeeList.autoExpands(count: MeetingAttendeeList.autoExpandLimit))
        XCTAssertFalse(MeetingAttendeeList.autoExpands(count: MeetingAttendeeList.autoExpandLimit + 1))
        XCTAssertFalse(MeetingAttendeeList.autoExpands(count: 202))
    }
}
