import XCTest
@testable import OWAWidget

/// Mapping rules for calendars read through EventKit.
///
/// Everything here runs on snapshot values: constructing a real `EKEventStore` risks the system
/// calendar prompt, and `swift test` gates `make release-package` — a prompt would hang packaging
/// the same way a Keychain dialog does.
final class EventKitEventMapperTests: XCTestCase {
    private let mapper = EventKitEventMapper()
    private let accountID = UUID()

    /// Verbatim from a real Google invitation as it arrives over CalDAV (probe dump, 2026-08-22).
    /// Two traps in one string: the link ends with a sentence period, and a `tel.meet` dial-in URL
    /// sits three lines below it.
    private let googleNotes = """
    -::~:~::~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~::~:~::-
    Присоединиться через Google Meet: https://meet.google.com/qzs-aqzm-ujj.
    Вы также можете позвонить по телефону: (RU) +7 499 951-64-31 PIN-код: 9393749296365#
    Дополнительные номера телефонов: https://tel.meet/qzs-aqzm-ujj?pin=9393749296365
    -::~:~::~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~::~:~::-
    """

    private func makeSnapshot(
        eventIdentifier: String? = "cal-1:event@google.com",
        title: String? = "Статус CRM",
        start: Date = Date(timeIntervalSinceReferenceDate: 1_000_000),
        end: Date = Date(timeIntervalSinceReferenceDate: 1_001_800),
        isAllDay: Bool = false,
        occurrenceDate: Date? = nil,
        status: EventKitEventStatus = .confirmed,
        url: URL? = nil,
        location: String? = nil,
        notes: String? = nil,
        organizer: EventKitParticipantSnapshot? = nil,
        attendees: [EventKitParticipantSnapshot] = []
    ) -> EventKitEventSnapshot {
        EventKitEventSnapshot(
            eventIdentifier: eventIdentifier,
            externalIdentifier: "event@google.com",
            calendarIdentifier: "cal-1",
            calendarTitle: "amio.env@gmail.com",
            title: title,
            startDate: start,
            endDate: end,
            isAllDay: isAllDay,
            occurrenceDate: occurrenceDate,
            hasRecurrenceRules: occurrenceDate != nil,
            status: status,
            url: url,
            location: location,
            notes: notes,
            organizer: organizer,
            attendees: attendees
        )
    }

    private func participant(
        name: String = "Кто-то",
        email: String? = "someone@example.com",
        isCurrentUser: Bool = false,
        role: EventKitParticipantRole = .required,
        status: EventKitParticipantStatus = .pending
    ) -> EventKitParticipantSnapshot {
        EventKitParticipantSnapshot(
            name: name,
            email: email,
            isCurrentUser: isCurrentUser,
            role: role,
            status: status
        )
    }

    // MARK: - Join link

    /// Google puts the Meet link in `conferenceData`, which CalDAV drops entirely — the note is
    /// the only place it survives, so this is the path that decides whether the app is useful.
    func testFindsGoogleMeetLinkInNotesDespiteTrailingPeriod() throws {
        let event = try XCTUnwrap(mapper.map(makeSnapshot(notes: googleNotes), accountID: accountID))

        XCTAssertEqual(event.joinURL?.absoluteString, "https://meet.google.com/qzs-aqzm-ujj")
        XCTAssertEqual(event.platform, .googleMeet)
    }

    func testDoesNotMistakeDialInLinkForTheMeeting() throws {
        let event = try XCTUnwrap(mapper.map(makeSnapshot(notes: googleNotes), accountID: accountID))

        XCTAssertFalse(event.joinURL?.absoluteString.contains("tel.meet") ?? false)
    }

    /// EventKit's `url` is a free-form field. When it holds something that is not a meeting — a
    /// link back to the event page, say — a recognised platform in the note must still win.
    func testRecognisedPlatformBeatsUnrelatedEventURL() throws {
        let snapshot = makeSnapshot(
            url: URL(string: "https://calendar.google.com/calendar/event?eid=abc"),
            notes: googleNotes
        )
        let event = try XCTUnwrap(mapper.map(snapshot, accountID: accountID))

        XCTAssertEqual(event.joinURL?.absoluteString, "https://meet.google.com/qzs-aqzm-ujj")
        XCTAssertEqual(event.platform, .googleMeet)
    }

    func testFallsBackToRawURLWhenNoPlatformIsRecognised() throws {
        let snapshot = makeSnapshot(url: URL(string: "https://example.com/room/42"), notes: "no links here")
        let event = try XCTUnwrap(mapper.map(snapshot, accountID: accountID))

        XCTAssertEqual(event.joinURL?.absoluteString, "https://example.com/room/42")
        XCTAssertEqual(event.platform, .generic)
    }

    func testFindsLinkInLocation() throws {
        let snapshot = makeSnapshot(location: "https://meet.google.com/abc-defg-hij")
        let event = try XCTUnwrap(mapper.map(snapshot, accountID: accountID))

        XCTAssertEqual(event.platform, .googleMeet)
    }

    func testNoLinkAnywhereLeavesJoinURLEmpty() throws {
        let event = try XCTUnwrap(mapper.map(makeSnapshot(notes: "просто текст"), accountID: accountID))

        XCTAssertNil(event.joinURL)
        XCTAssertEqual(event.platform, .generic)
    }

    // MARK: - Identity

    /// EventKit gives every occurrence of a series the same `eventIdentifier`. Without the
    /// occurrence anchor a weekly stand-up collapses into one event in the cache and on the
    /// timeline — and most Google events in practice are recurring.
    func testRecurringOccurrencesGetDistinctIdentities() throws {
        let week: TimeInterval = 7 * 24 * 3600
        let first = makeSnapshot(occurrenceDate: Date(timeIntervalSinceReferenceDate: 1_000_000))
        let second = makeSnapshot(
            start: Date(timeIntervalSinceReferenceDate: 1_000_000 + week),
            end: Date(timeIntervalSinceReferenceDate: 1_001_800 + week),
            occurrenceDate: Date(timeIntervalSinceReferenceDate: 1_000_000 + week)
        )

        let a = try XCTUnwrap(mapper.map(first, accountID: accountID))
        let b = try XCTUnwrap(mapper.map(second, accountID: accountID))
        XCTAssertNotEqual(a.id, b.id)
    }

    /// Dragging one instance to another time must not read as a different meeting, or its
    /// notification and join history would restart from scratch.
    func testMovedInstanceKeepsItsIdentity() throws {
        let occurrence = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let original = makeSnapshot(occurrenceDate: occurrence)
        let moved = makeSnapshot(
            start: Date(timeIntervalSinceReferenceDate: 1_003_600),
            end: Date(timeIntervalSinceReferenceDate: 1_005_400),
            occurrenceDate: occurrence
        )

        let a = try XCTUnwrap(mapper.map(original, accountID: accountID))
        let b = try XCTUnwrap(mapper.map(moved, accountID: accountID))
        XCTAssertEqual(a.id, b.id)
    }

    func testFallsBackToExternalIdentifierWhenEventIdentifierIsMissing() throws {
        let event = try XCTUnwrap(
            mapper.map(makeSnapshot(eventIdentifier: nil), accountID: accountID)
        )

        XCTAssertTrue(event.id.hasPrefix("event@google.com|"))
    }

    // MARK: - RSVP and degradation

    /// RSVP controls in the detail panel key off `changeKey`. This provider cannot answer
    /// invitations, so leaving it nil is what hides the buttons — no capability flag involved.
    func testLeavesChangeKeyEmptySoResponseControlsStayHidden() throws {
        let event = try XCTUnwrap(mapper.map(makeSnapshot(), accountID: accountID))

        XCTAssertNil(event.changeKey)
        XCTAssertNil(event.instanceKey)
    }

    func testReadsResponseFromTheCurrentUsersParticipation() throws {
        let snapshot = makeSnapshot(attendees: [
            participant(name: "Коллега", status: .accepted),
            participant(name: "Я", email: "me@example.com", isCurrentUser: true, status: .declined)
        ])
        let event = try XCTUnwrap(mapper.map(snapshot, accountID: accountID))

        XCTAssertEqual(event.responseType, .declined)
    }

    func testOrganiserOutranksParticipationStatus() throws {
        let snapshot = makeSnapshot(
            organizer: participant(name: "Я", isCurrentUser: true),
            attendees: [participant(name: "Я", isCurrentUser: true, status: .pending)]
        )
        let event = try XCTUnwrap(mapper.map(snapshot, accountID: accountID))

        XCTAssertTrue(event.isOrganizer)
        XCTAssertEqual(event.responseType, .organizer)
    }

    func testPendingParticipationReadsAsNotResponded() throws {
        let snapshot = makeSnapshot(attendees: [
            participant(isCurrentUser: true, status: .pending)
        ])
        let event = try XCTUnwrap(mapper.map(snapshot, accountID: accountID))

        XCTAssertEqual(event.responseType, .notResponded)
    }

    func testMapsAttendeeRoles() throws {
        let snapshot = makeSnapshot(attendees: [
            participant(name: "Обязательный", role: .required, status: .accepted),
            participant(name: "Необязательный", email: "opt@example.com", role: .optional, status: .tentative)
        ])
        let event = try XCTUnwrap(mapper.map(snapshot, accountID: accountID))
        let attendees = try XCTUnwrap(event.detailedAttendees)

        XCTAssertEqual(attendees.count, 2)
        XCTAssertEqual(attendees[0].kind, .required)
        XCTAssertEqual(attendees[0].response, .accepted)
        XCTAssertEqual(attendees[1].kind, .optional)
        XCTAssertEqual(attendees[1].response, .tentative)
    }

    /// EventKit hands over participants and the note in the same pass, so `loadDetails` must find
    /// them already cached instead of asking the provider — which is what makes the detail panel
    /// open without a round trip.
    func testFillsDetailsSoTheyNeverLoadLazily() throws {
        let snapshot = makeSnapshot(notes: googleNotes, attendees: [participant()])
        let event = try XCTUnwrap(mapper.map(snapshot, accountID: accountID))

        XCTAssertNotNil(event.detailedAttendees)
        XCTAssertNotNil(event.fullBody)
        XCTAssertNil(event.fullBodyHTML)
    }

    // MARK: - Flags

    func testCarriesAllDayAndCancelledFlags() throws {
        let allDay = try XCTUnwrap(mapper.map(makeSnapshot(isAllDay: true), accountID: accountID))
        XCTAssertTrue(allDay.isAllDay)

        let cancelled = try XCTUnwrap(mapper.map(makeSnapshot(status: .canceled), accountID: accountID))
        XCTAssertTrue(cancelled.isCancelled)
        XCTAssertNil(cancelled.joinURLForActions)
    }

    func testDropsEventThatEndsBeforeItStarts() {
        let broken = makeSnapshot(
            start: Date(timeIntervalSinceReferenceDate: 1_001_800),
            end: Date(timeIntervalSinceReferenceDate: 1_000_000)
        )
        XCTAssertNil(mapper.map(broken, accountID: accountID))
    }

    func testAssignsTheOwningAccount() throws {
        let event = try XCTUnwrap(mapper.map(makeSnapshot(), accountID: accountID))
        XCTAssertEqual(event.accountID, accountID)
    }
}
