import XCTest
@testable import OWAWidget

/// Covers the `detailedAttendees` field on `CalendarEvent`: the copy helper, Codable round-tripping
/// (the event is persisted to the on-disk cache), backward compatibility with pre-feature payloads,
/// and `EventAttendee` identity.
final class CalendarEventAttendeesTests: XCTestCase {

    private func makeEvent() -> CalendarEvent {
        CalendarEvent(
            id: "e1",
            title: "T",
            startDate: Date(timeIntervalSince1970: 0),
            endDate: Date(timeIntervalSince1970: 60),
            location: nil,
            bodyPreview: nil,
            joinURL: nil,
            platform: .generic,
            isAllDay: false,
            organizer: nil,
            accountID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        )
    }

    func testWithDetailedAttendeesReplacesListAndKeepsOtherFields() {
        let event = makeEvent()
        XCTAssertNil(event.detailedAttendees)

        let list = [EventAttendee(name: "A", email: "a@b.c", kind: .required, response: .accepted)]
        let updated = event.withDetailedAttendees(list)

        XCTAssertEqual(updated.detailedAttendees, list)
        XCTAssertEqual(updated.id, event.id)
        XCTAssertEqual(updated.title, event.title)
        XCTAssertEqual(updated.accountID, event.accountID)
    }

    func testCodableRoundTripPreservesDetailedAttendees() throws {
        let list = [
            EventAttendee(name: "A", email: "a@b.c", kind: .required, response: .accepted),
            EventAttendee(name: "B", email: nil, kind: .optional, response: .notResponded),
        ]
        let event = makeEvent().withDetailedAttendees(list)

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
