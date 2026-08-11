import XCTest
@testable import OWAWidget

/// Covers the `detailedAttendees` field on `CalendarEvent`: the copy helper, Codable round-tripping
/// (the event is persisted to the on-disk cache), backward compatibility with pre-feature payloads,
/// and `EventAttendee` identity.
final class CalendarEventAttendeesTests: XCTestCase {

    private func makeEvent(bodyPreview: String? = nil) -> CalendarEvent {
        CalendarEvent(
            id: "e1",
            title: "T",
            startDate: Date(timeIntervalSince1970: 0),
            endDate: Date(timeIntervalSince1970: 60),
            location: nil,
            bodyPreview: bodyPreview,
            joinURL: nil,
            platform: .generic,
            isAllDay: false,
            organizer: nil,
            accountID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        )
    }

    func testWithDetailsReplacesListAndKeepsOtherFields() {
        let event = makeEvent()
        XCTAssertNil(event.detailedAttendees)

        let list = [EventAttendee(name: "A", email: "a@b.c", kind: .required, response: .accepted)]
        let updated = event.withDetails(CalendarEventDetails(attendees: list, body: "Полная повестка"))

        XCTAssertEqual(updated.detailedAttendees, list)
        XCTAssertEqual(updated.fullBody, "Полная повестка")
        XCTAssertEqual(updated.id, event.id)
        XCTAssertEqual(updated.title, event.title)
        XCTAssertEqual(updated.accountID, event.accountID)
    }

    /// A refetch that returns no body must not drop the agenda back to the truncated preview.
    func testWithDetailsKeepsCachedBodyWhenNewOneIsMissing() {
        let event = makeEvent().withDetails(CalendarEventDetails(attendees: [], body: "Полная повестка"))

        let updated = event.withDetails(CalendarEventDetails(attendees: [], body: nil))

        XCTAssertEqual(updated.fullBody, "Полная повестка")
    }

    /// `displayBody` shows the full agenda once loaded and the 255-char preview until then.
    func testDisplayBodyPrefersFullBodyOverPreview() {
        let event = makeEvent(bodyPreview: "Обрезанная повестка")
        XCTAssertEqual(event.displayBody, "Обрезанная повестка")

        let loaded = event.withDetails(CalendarEventDetails(attendees: [], body: "Полная повестка"))
        XCTAssertEqual(loaded.displayBody, "Полная повестка")
    }

    func testCodableRoundTripPreservesDetailedAttendees() throws {
        let list = [
            EventAttendee(name: "A", email: "a@b.c", kind: .required, response: .accepted),
            EventAttendee(name: "B", email: nil, kind: .optional, response: .notResponded),
        ]
        let event = makeEvent().withDetails(CalendarEventDetails(attendees: list))

        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(CalendarEvent.self, from: data)

        XCTAssertEqual(decoded.detailedAttendees, list)
    }

    func testLegacyPayloadWithoutDetailedAttendeesDecodesToNil() throws {
        // Events cached before this feature have no detailedAttendees key — must not break decoding.
        let data = try JSONEncoder().encode(makeEvent())
        let decoded = try JSONDecoder().decode(CalendarEvent.self, from: data)
        XCTAssertNil(decoded.detailedAttendees)
    }

    func testEventAttendeeIdPrefersEmailThenFallsBackToName() {
        XCTAssertEqual(
            EventAttendee(name: "A", email: "a@b.c", kind: .required, response: .accepted).id,
            "a@b.c|required"
        )
        XCTAssertEqual(
            EventAttendee(name: "A", email: nil, kind: .optional, response: .accepted).id,
            "A|optional"
        )
    }
}
