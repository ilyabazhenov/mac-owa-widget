import XCTest
@testable import OWAWidget

/// Answering invitations and loading meeting details.
///
/// The `MeetingResponse` request is built from an **unverified** token table (page 8). A wrong
/// token there is accepted by the server and changes nothing, so these tests pin the request
/// shape — they cannot prove the tokens are right, only that the shape stays what was verified
/// by round-trip against the live server.
final class EASMeetingResponseTests: XCTestCase {

    private let accountID = UUID()

    private func session(
        _ transport: ScriptedTransport,
        store: any EASSyncStoring = EASInMemorySyncStore()
    ) -> EASAccountSession {
        EASAccountSession(accountID: accountID, client: transport, store: store, filterType: 0)
    }

    private func restoredStore(items: [EASCalendarItem], syncKey: String = "5") -> EASInMemorySyncStore {
        EASInMemorySyncStore(
            EASSyncSnapshot(
                version: EASSyncSnapshot.currentVersion,
                savedAt: Date(),
                collectionId: "20",
                syncKey: syncKey,
                filterType: 0,
                items: items
            )
        )
    }

    // MARK: The action mapping

    /// `UserResponse` values come from [MS-ASCMD]; swapping two of them would silently accept a
    /// meeting the user declined.
    func testUserResponseValues() {
        XCTAssertEqual(EASMeetingResponse(.accept).rawValue, 1)
        XCTAssertEqual(EASMeetingResponse(.tentative).rawValue, 2)
        XCTAssertEqual(EASMeetingResponse(.decline).rawValue, 3)
    }

    // MARK: Addressing the reply

    func testRespondAddressesTheAppointmentInItsCollection() async throws {
        let transport = ScriptedTransport([])
        let session = session(transport, store: restoredStore(items: [makeItem("20:7")]))

        try await session.respond(serverId: "20:7", instanceId: nil, response: .accepted)

        let calls = await transport.respondCalls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.collectionId, "20", "the calendar collection, from the session")
        XCTAssertEqual(calls.first?.requestId, "20:7")
        XCTAssertNil(calls.first?.instanceId)
        XCTAssertEqual(calls.first?.response, .accepted)
    }

    /// Answering one occurrence and answering the whole series are different actions. Dropping
    /// the instance identifier turns "I cannot make Tuesday" into "I am leaving this meeting".
    func testRespondToOneOccurrenceCarriesTheInstanceId() async throws {
        let transport = ScriptedTransport([])
        let session = session(transport, store: restoredStore(items: [makeItem("20:9")]))

        try await session.respond(
            serverId: "20:9",
            instanceId: "20260916T070000Z",
            response: .declined
        )

        let calls = await transport.respondCalls
        XCTAssertEqual(calls.first?.instanceId, "20260916T070000Z")
        XCTAssertEqual(calls.first?.response, .declined)
    }

    func testRespondProvisionsFirstWhenTheSessionIsCold() async throws {
        let transport = ScriptedTransport([])
        let session = session(transport)     // no snapshot: nothing resolved yet

        try await session.respond(serverId: "20:7", instanceId: nil, response: .tentative)

        let provisions = await transport.provisionCount
        let folders = await transport.folderCount
        XCTAssertEqual(provisions, 1)
        XCTAssertEqual(folders, 1, "the collection has to be resolved before a reply can be addressed")
    }

    func testRespondPropagatesAServerRejection() async throws {
        let transport = ScriptedTransport([])
        await transport.setRespondError(EASError.commandStatus(command: "MeetingResponse", status: "2"))
        let session = session(transport, store: restoredStore(items: [makeItem("20:7")]))

        do {
            try await session.respond(serverId: "20:7", instanceId: nil, response: .accepted)
            XCTFail("expected the rejection to propagate")
        } catch {
            guard case EASError.commandStatus(command: "MeetingResponse", status: "2") = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
    }

    // MARK: Loading the full body

    func testUntruncatedBodyIsServedFromTheLocalCopy() async throws {
        var item = makeItem("20:7")
        item.bodyText = "Short agenda"
        item.bodyTruncated = false

        let transport = ScriptedTransport([])
        let session = session(transport, store: restoredStore(items: [item]))

        let loaded = try await session.fullItem(serverId: "20:7")

        XCTAssertEqual(loaded?.bodyText, "Short agenda")
        let fetched = await transport.fetchedServerIds
        XCTAssertTrue(fetched.isEmpty, "a complete body must not cost a request")
    }

    func testTruncatedBodyIsFetched() async throws {
        var stored = makeItem("20:7")
        stored.bodyText = "Beginning of a long agenda"
        stored.bodyTruncated = true

        var full = makeItem("20:7")
        full.bodyText = "Beginning of a long agenda, and the rest of it"
        full.bodyTruncated = false

        let transport = ScriptedTransport([])
        await transport.setFetchResult(full)
        let store = restoredStore(items: [stored])
        let session = session(transport, store: store)

        let loaded = try await session.fullItem(serverId: "20:7")

        XCTAssertEqual(loaded?.bodyText, "Beginning of a long agenda, and the rest of it")
        let fetched = await transport.fetchedServerIds
        XCTAssertEqual(fetched, ["20:7"])
    }

    /// The fetch response describes one item and carries no recurrence rule. Overwriting the
    /// cached copy wholesale would turn a series into a single meeting.
    func testFetchKeepsTheRecurrenceRuleFromTheSync() async throws {
        var stored = makeItem("20:9")
        stored.bodyTruncated = true
        stored.recurrence = EASRecurrence(kind: .weekly, interval: 1, dayOfWeekMask: 4)
        stored.exceptions = [
            EASException(originalStart: Date(timeIntervalSince1970: 1_800_000_000), isDeleted: true)
        ]

        var full = makeItem("20:9")
        full.bodyText = "Full agenda"
        full.bodyTruncated = false          // and no recurrence

        let transport = ScriptedTransport([])
        await transport.setFetchResult(full)
        let session = session(transport, store: restoredStore(items: [stored]))

        let loaded = try await session.fullItem(serverId: "20:9")

        XCTAssertEqual(loaded?.bodyText, "Full agenda")
        XCTAssertTrue(loaded?.isRecurring ?? false, "the series must survive the fetch")
        XCTAssertEqual(loaded?.exceptions.count, 1)
    }

    /// A `Fetch` advances the synchronisation key like any other `Sync`. Losing the new one
    /// would make the next ordinary sync fail with an invalid key.
    func testFetchPersistsTheAdvancedSyncKey() async throws {
        var stored = makeItem("20:7")
        stored.bodyTruncated = true

        let transport = ScriptedTransport([])
        await transport.setFetchResult(stored)
        let store = restoredStore(items: [stored], syncKey: "5")
        let session = session(transport, store: store)

        _ = try await session.fullItem(serverId: "20:7")

        XCTAssertEqual(store.load()?.syncKey, "5f", "the key the fetch returned is the live one")
    }

    func testUnknownItemYieldsNothing() async throws {
        let transport = ScriptedTransport([])
        let session = session(transport, store: restoredStore(items: [makeItem("20:7")]))
        let loaded = try await session.fullItem(serverId: "20:999")
        XCTAssertNil(loaded)
    }

    // MARK: Mapping details

    func testDetailsCarryAttendeeKindsAndResponses() {
        var item = makeItem("20:7")
        item.bodyText = "Agenda"
        item.attendees = [
            EASAttendee(name: "Anna", email: "anna@example.com", type: 1, status: 3),
            EASAttendee(name: "Boris", email: "boris@example.com", type: 2, status: 4),
            EASAttendee(name: "Room 3", email: "room3@example.com", type: 3, status: 2),
            EASAttendee(name: "Clara", email: "clara@example.com", type: nil, status: nil),
        ]

        let details = EASCalendarMapper.details(from: item, instanceKey: nil)

        XCTAssertEqual(details.body, "Agenda")
        XCTAssertEqual(details.attendees.map(\.kind), [.required, .optional, .required, .required],
                       "a room is not an optional guest")
        XCTAssertEqual(details.attendees.map(\.response),
                       [.accepted, .declined, .tentative, .notResponded])
    }

    /// When the organiser changed one occurrence, its own attendee list and agenda win.
    func testDetailsOfAModifiedOccurrenceUseTheOverride() {
        let original = EASDate.parse("20260916T070000Z")!
        var item = makeItem("20:9")
        item.bodyText = "Series agenda"
        item.attendees = [EASAttendee(name: "Anna", email: "a@example.com", type: 1, status: 3)]
        item.recurrence = EASRecurrence(kind: .daily, interval: 1)
        item.exceptions = [
            EASException(
                originalStart: original,
                isDeleted: false,
                bodyText: "Just this once: different agenda",
                attendees: [EASAttendee(name: "Boris", email: "b@example.com", type: 2, status: 2)]
            )
        ]

        let overridden = EASCalendarMapper.details(from: item, instanceKey: "20260916T070000Z")
        XCTAssertEqual(overridden.body, "Just this once: different agenda")
        XCTAssertEqual(overridden.attendees.map(\.name), ["Boris"])

        let other = EASCalendarMapper.details(from: item, instanceKey: "20260917T070000Z")
        XCTAssertEqual(other.body, "Series agenda", "an untouched occurrence inherits the master")
        XCTAssertEqual(other.attendees.map(\.name), ["Anna"])
    }

    func testAttendeeResponseMapping() {
        XCTAssertEqual(EASCalendarMapper.attendeeResponse(2), .tentative)
        XCTAssertEqual(EASCalendarMapper.attendeeResponse(3), .accepted)
        XCTAssertEqual(EASCalendarMapper.attendeeResponse(4), .declined)
        XCTAssertEqual(EASCalendarMapper.attendeeResponse(5), .notResponded)
        XCTAssertEqual(EASCalendarMapper.attendeeResponse(0), .notResponded)
        XCTAssertEqual(EASCalendarMapper.attendeeResponse(nil), .notResponded)
    }
}
