import XCTest
@testable import OWAWidget

/// Covers the attendee-list presentation rules: organizer removal (by name match and by an explicit
/// `Organizer` response) and alphabetical sorting, while preserving each attendee's `kind`.
final class MeetingAttendeeListTests: XCTestCase {

    private func attendee(_ name: String, kind: EventAttendeeKind = .required, response: MeetingResponseType = .notResponded) -> EventAttendee {
        EventAttendee(name: name, email: nil, kind: kind, response: response)
    }

    func testRemovesOrganizerByNameMatch() {
        let input = [attendee("Чернов Михаил"), attendee("Баженов Илья")]
        let result = MeetingAttendeeList.forDisplay(input, organizer: "  Чернов Михаил ")
        XCTAssertEqual(result.map(\.name), ["Баженов Илья"])
    }

    func testRemovesOrganizerByResponseType() {
        let input = [attendee("Some Organizer", response: .organizer), attendee("Real Attendee")]
        let result = MeetingAttendeeList.forDisplay(input, organizer: nil)
        XCTAssertEqual(result.map(\.name), ["Real Attendee"])
    }

    func testSortsAlphabeticallyCaseInsensitively() {
        let input = [attendee("Юшина Оксана"), attendee("Аниканов Алексей"), attendee("баженов илья")]
        let result = MeetingAttendeeList.forDisplay(input, organizer: nil)
        XCTAssertEqual(result.map(\.name), ["Аниканов Алексей", "баженов илья", "Юшина Оксана"])
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
}
