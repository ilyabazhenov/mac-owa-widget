import XCTest
@testable import OWAWidget

/// Creating a meeting.
///
/// ActiveSync splits this in two, and only the second half invites anyone: `Sync Add` writes the
/// appointment to the organiser's calendar, and a `SendMail` carrying a `METHOD:REQUEST` body is
/// what reaches the attendees. Both halves fail silently — a wrong attendee type quietly demotes
/// someone to optional, a wrong meeting status produces an item that cannot collect responses,
/// and a missing invitation produces a meeting only its organiser can see.
final class EASCreateMeetingTests: XCTestCase {

    private let accountID = UUID()
    private let start = EASDate.parse("20260915T070000Z")!
    private let end = EASDate.parse("20260915T080000Z")!
    private let moscow = TimeZone(secondsFromGMT: 3 * 3600)!

    private func person(_ name: String, _ email: String) -> ResolvedAttendee {
        ResolvedAttendee(displayName: name, email: email, jobTitle: nil)
    }

    private func body(
        subject: String = "Планёрка",
        agenda: String = "",
        location: String = "",
        required: [ResolvedAttendee] = [],
        optional: [ResolvedAttendee] = []
    ) throws -> WBNode {
        let data = EASClient.createEventBody(
            collectionId: "20",
            syncKey: "7",
            subject: subject,
            agenda: agenda,
            location: location,
            start: start,
            end: end,
            requiredAttendees: required,
            optionalAttendees: optional,
            timeZone: moscow,
            clientId: "CID",
            uid: "UID",
            stamp: start
        )
        let tree = try WBXMLReader.parse(data)
        return try XCTUnwrap(tree.first(AS.applicationData))
    }

    // MARK: The request body

    func testCarriesTheCoreFields() throws {
        let item = try body(subject: "Планёрка", agenda: "Повестка", location: "Переговорная 3")

        XCTAssertEqual(item.value(CAL.subject), "Планёрка")
        XCTAssertEqual(item.value(CAL.location), "Переговорная 3")
        XCTAssertEqual(item.value(CAL.startTime), "20260915T070000Z")
        XCTAssertEqual(item.value(CAL.endTime), "20260915T080000Z")
        XCTAssertEqual(item.value(CAL.uid), "UID")
        XCTAssertEqual(item.value(CAL.allDayEvent), "0")
        XCTAssertEqual(item.child(ASB.body)?.value(ASB.data), "Повестка")
    }

    func testOmitsEmptyOptionalFields() throws {
        let item = try body(agenda: "", location: "")
        XCTAssertNil(item.child(CAL.location), "an empty location is left out, not sent blank")
        XCTAssertNil(item.child(ASB.body))
    }

    /// The calendar class is a sequence. A reordered body risks outright rejection, and the
    /// specification lists the elements in ascending token order.
    func testElementsAreInAscendingTokenOrder() throws {
        let item = try body(
            agenda: "Повестка",
            location: "Переговорная 3",
            required: [person("Анна", "anna@example.com")]
        )
        let calendarTokens = item.children.compactMap { node -> Int? in
            guard let tag = node.tag, tag.page == 4 else { return nil }
            return tag.code
        }
        XCTAssertEqual(calendarTokens, calendarTokens.sorted(), "calendar elements must ascend")
        XCTAssertFalse(calendarTokens.isEmpty)
    }

    // MARK: Attendees

    func testRequiredAndOptionalAttendeesGetDistinctTypes() throws {
        let item = try body(
            required: [person("Анна", "anna@example.com")],
            optional: [person("Борис", "boris@example.com")]
        )
        let attendees = try XCTUnwrap(item.child(CAL.attendees)).all(CAL.attendee)
        XCTAssertEqual(attendees.count, 2)

        XCTAssertEqual(attendees[0].value(CAL.email), "anna@example.com")
        XCTAssertEqual(attendees[0].value(CAL.attendeeType), "1", "1 = required")

        XCTAssertEqual(attendees[1].value(CAL.email), "boris@example.com")
        XCTAssertEqual(attendees[1].value(CAL.attendeeType), "2", "2 = optional")
    }

    func testAttendeeWithoutANameFallsBackToTheAddress() throws {
        let item = try body(required: [person("", "anna@example.com")])
        let attendee = try XCTUnwrap(item.child(CAL.attendees)?.all(CAL.attendee).first)
        XCTAssertEqual(attendee.value(CAL.name), "anna@example.com")
    }

    /// `MeetingStatus` is what turns an appointment into a meeting. With attendees and a status
    /// of 0, Exchange stores it privately and sends nothing — the invitations simply never
    /// arrive, and the organiser has no way to tell.
    func testMeetingStatusReflectsWhetherAnyoneIsInvited() throws {
        let withGuests = try body(required: [person("Анна", "anna@example.com")])
        XCTAssertEqual(withGuests.value(CAL.meetingStatus), "1")
        XCTAssertNotNil(withGuests.child(CAL.attendees))

        let alone = try body()
        XCTAssertEqual(alone.value(CAL.meetingStatus), "0", "no guests means no meeting request")
        XCTAssertNil(alone.child(CAL.attendees), "an empty attendee collection is not sent")
    }

    // MARK: The timezone blob

    func testGeneratedBlobRoundTripsThroughTheParser() throws {
        let blob = EASWindowsTimeZone.blob(for: moscow, at: start)
        let parsed = try XCTUnwrap(EASWindowsTimeZone.parse(base64: blob))

        // Windows states the offset as minutes to add to local time to reach UTC, so UTC+3
        // is −180. Getting the sign wrong would place the meeting six hours away.
        XCTAssertEqual(parsed.bias, -180)
        XCTAssertFalse(parsed.observesDaylightSaving)

        var noon = DateComponents()
        noon.year = 2026; noon.month = 9; noon.day = 15; noon.hour = 12
        XCTAssertEqual(parsed.utcOffsetSeconds(forLocal: noon), 3 * 3600)
    }

    func testBlobIsTheRightLength() throws {
        let blob = EASWindowsTimeZone.blob(for: moscow)
        let data = try XCTUnwrap(Data(base64Encoded: blob))
        XCTAssertEqual(data.count, 172, "TIME_ZONE_INFORMATION is a fixed-size structure")
    }

    /// The standard offset is what goes out, not the current one — otherwise a meeting created
    /// in summer would carry a different zone from the same meeting created in winter.
    func testBlobUsesTheStandardOffsetNotTheSeasonalOne() throws {
        guard let berlin = TimeZone(identifier: "Europe/Berlin") else {
            throw XCTSkip("Europe/Berlin is unavailable on this system")
        }
        let summer = EASDate.parse("20260715T120000Z")!
        let winter = EASDate.parse("20260115T120000Z")!

        let fromSummer = try XCTUnwrap(EASWindowsTimeZone.parse(base64: .init(EASWindowsTimeZone.blob(for: berlin, at: summer))))
        let fromWinter = try XCTUnwrap(EASWindowsTimeZone.parse(base64: .init(EASWindowsTimeZone.blob(for: berlin, at: winter))))

        XCTAssertEqual(fromSummer.bias, fromWinter.bias)
        XCTAssertEqual(fromWinter.bias, -60, "Central European standard time is UTC+1")
    }

    // MARK: The session

    private func session(
        _ transport: ScriptedTransport,
        store: any EASSyncStoring = EASInMemorySyncStore()
    ) -> EASAccountSession {
        EASAccountSession(accountID: accountID, client: transport, store: store, filterType: 0)
    }

    func testCreationUsesTheLiveCollectionAndKey() async throws {
        let store = EASInMemorySyncStore(
            EASSyncSnapshot(
                version: EASSyncSnapshot.currentVersion,
                savedAt: Date(),
                collectionId: "20",
                syncKey: "7",
                filterType: 0,
                items: []
            )
        )
        let transport = ScriptedTransport([])
        let session = session(transport, store: store)

        try await session.createEvent(
            subject: "Планёрка",
            agenda: "",
            location: "",
            start: start,
            end: end,
            requiredAttendees: [person("Анна", "anna@example.com")],
            optionalAttendees: [person("Борис", "boris@example.com")],
            timeZone: moscow,
            organizerName: "Алексей",
            organizerFallbackEmail: "me@example.com"
        )

        let calls = await transport.createCalls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.collectionId, "20")
        XCTAssertEqual(calls.first?.syncKey, "7")
        XCTAssertEqual(calls.first?.required, ["anna@example.com"])
        XCTAssertEqual(calls.first?.optional, ["boris@example.com"])
    }

    /// A creation is a `Sync` and advances the chain. Sending a key the server has not issued
    /// yet would simply fail, so a cold session synchronises first.
    func testColdSessionSynchronisesBeforeCreating() async throws {
        let transport = ScriptedTransport([
            .result(EASSyncResult(syncKey: "1", moreAvailable: false, upserted: [], deletedIds: [])),
            .result(EASSyncResult(syncKey: "2", moreAvailable: false, upserted: [], deletedIds: [])),
        ])
        let session = session(transport)

        try await session.createEvent(
            subject: "Планёрка", agenda: "", location: "",
            start: start, end: end,
            requiredAttendees: [], optionalAttendees: [], timeZone: moscow,
            organizerName: "Алексей",
            organizerFallbackEmail: "me@example.com"
        )

        let requested = await transport.syncKeysRequested
        XCTAssertEqual(requested, ["0", "1"], "primed and synced first")
        let calls = await transport.createCalls
        XCTAssertEqual(calls.first?.syncKey, "2", "the creation carries the key the sync produced")
    }

    func testCreationPersistsTheAdvancedKey() async throws {
        let store = EASInMemorySyncStore(
            EASSyncSnapshot(
                version: EASSyncSnapshot.currentVersion,
                savedAt: Date(),
                collectionId: "20",
                syncKey: "7",
                filterType: 0,
                items: []
            )
        )
        let session = session(ScriptedTransport([]), store: store)

        try await session.createEvent(
            subject: "Планёрка", agenda: "", location: "",
            start: start, end: end,
            requiredAttendees: [], optionalAttendees: [], timeZone: moscow,
            organizerName: "Алексей",
            organizerFallbackEmail: "me@example.com"
        )

        // The key advances twice: first for Add, then to fetch the created item — Fetch is also
        // Sync. Losing either update would break the next ordinary synchronization.
        XCTAssertEqual(store.load()?.syncKey, "7cf", "losing it would break the next ordinary sync")
    }

    func testCreationFailurePropagates() async throws {
        let transport = ScriptedTransport([])
        await transport.setCreateError(EASError.commandStatus(command: "Sync Add", status: "6"))
        let store = EASInMemorySyncStore(
            EASSyncSnapshot(
                version: EASSyncSnapshot.currentVersion,
                savedAt: Date(), collectionId: "20", syncKey: "7", filterType: 0, items: []
            )
        )
        let session = session(transport, store: store)

        do {
            try await session.createEvent(
                subject: "Планёрка", agenda: "", location: "",
                start: start, end: end,
                requiredAttendees: [], optionalAttendees: [], timeZone: moscow,
                organizerName: "Алексей",
                organizerFallbackEmail: "me@example.com"
            )
            XCTFail("expected the rejection to reach the caller")
        } catch {
            guard case EASError.commandStatus(command: "Sync Add", status: "6") = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
    }

    /// ActiveSync does not send an item created by this device back: `ServerId` was returned by
    /// `Add`, so the server considers the device to know about the meeting. Without an explicit
    /// fetch, the meeting exists on the server and in OWA but does not appear in the widget.
    func testCreatedEventIsFetchedIntoTheLocalMap() async throws {
        var created = makeItem("20:new")
        created.subject = "Планёрка"

        let transport = ScriptedTransport([])
        await transport.setFetchResult(created)
        let store = EASInMemorySyncStore(
            EASSyncSnapshot(
                version: EASSyncSnapshot.currentVersion,
                savedAt: Date(), collectionId: "20", syncKey: "7", filterType: 0, items: []
            )
        )
        let session = session(transport, store: store)

        try await session.createEvent(
            subject: "Планёрка", agenda: "", location: "",
            start: start, end: end,
            requiredAttendees: [person("Анна", "anna@example.com")],
            optionalAttendees: [], timeZone: moscow,
            organizerName: "Алексей",
            organizerFallbackEmail: "me@example.com"
        )

        let fetched = await transport.fetchedServerIds
        XCTAssertEqual(fetched, ["20:new"], "созданная встреча должна быть запрошена явно")

        let items = await session.currentItems().map(\.serverId)
        XCTAssertEqual(items, ["20:new"], "и попасть в локальную карту, иначе виджет её не покажет")
        XCTAssertEqual(store.load()?.items.count, 1, "и в снимок, чтобы пережить перезапуск")
    }

    /// The server may issue a ServerId but not return the item through Fetch. Waiting for the
    /// next full resync is not acceptable: externally it looks as if the meeting was not created,
    /// even though it exists in OWA and for attendees.
    func testEventIsRebuiltLocallyWhenTheServerReturnsNoItem() async throws {
        let transport = ScriptedTransport([])
        await transport.setFetchResult(nil)          // Fetch вернул пусто
        let store = EASInMemorySyncStore(
            EASSyncSnapshot(
                version: EASSyncSnapshot.currentVersion,
                savedAt: Date(), collectionId: "20", syncKey: "7", filterType: 0, items: []
            )
        )
        let session = session(transport, store: store)

        try await session.createEvent(
            subject: "Планёрка", agenda: "Повестка", location: "Переговорная 3",
            start: start, end: end,
            requiredAttendees: [person("Анна", "anna@example.com")],
            optionalAttendees: [person("Борис", "boris@example.com")],
            timeZone: moscow,
            organizerName: "Алексей",
            organizerFallbackEmail: "me@example.com"
        )

        let items = await session.currentItems()
        let created = try XCTUnwrap(items.first)
        XCTAssertEqual(created.serverId, "20:new")
        XCTAssertEqual(created.subject, "Планёрка")
        XCTAssertEqual(created.location, "Переговорная 3")
        XCTAssertEqual(created.start, start)
        XCTAssertEqual(created.end, end)
        XCTAssertEqual(created.attendees.map(\.email), ["anna@example.com", "boris@example.com"])
        XCTAssertEqual(created.attendees.map(\.type), [1, 2], "обязательный и необязательный")
        XCTAssertTrue(created.isOrganizer, "встречу организовали мы")
        XCTAssertFalse(created.isRecurring)
        XCTAssertTrue(created.bodyTruncated, "opening details must fetch the server version")

        // It must survive restart rather than merely appear once.
        XCTAssertEqual(store.load()?.items.count, 1)
    }

    /// A personal item without attendees is not a meeting and has nobody to invite.
    func testLocallyRebuiltEventWithoutAttendeesIsNotAMeeting() async throws {
        let transport = ScriptedTransport([])
        await transport.setFetchResult(nil)
        let store = EASInMemorySyncStore(
            EASSyncSnapshot(
                version: EASSyncSnapshot.currentVersion,
                savedAt: Date(), collectionId: "20", syncKey: "7", filterType: 0, items: []
            )
        )
        let session = session(transport, store: store)

        try await session.createEvent(
            subject: "Фокус-время", agenda: "", location: "",
            start: start, end: end,
            requiredAttendees: [], optionalAttendees: [], timeZone: moscow,
            organizerName: "Алексей",
            organizerFallbackEmail: "me@example.com"
        )

        let items = await session.currentItems()
        let created = try XCTUnwrap(items.first)
        XCTAssertFalse(created.isMeeting)
        XCTAssertNil(created.location, "пустое поле не превращается в пустую строку")
    }

    /// The server version always takes precedence over the locally built one.
    func testServerVersionWinsWhenTheFetchSucceeds() async throws {
        var fromServer = makeItem("20:new")
        fromServer.subject = "Планёрка (как сохранил сервер)"

        let transport = ScriptedTransport([])
        await transport.setFetchResult(fromServer)
        let store = EASInMemorySyncStore(
            EASSyncSnapshot(
                version: EASSyncSnapshot.currentVersion,
                savedAt: Date(), collectionId: "20", syncKey: "7", filterType: 0, items: []
            )
        )
        let session = session(transport, store: store)

        try await session.createEvent(
            subject: "Планёрка", agenda: "", location: "",
            start: start, end: end,
            requiredAttendees: [], optionalAttendees: [], timeZone: moscow,
            organizerName: "Алексей",
            organizerFallbackEmail: "me@example.com"
        )

        let items = await session.currentItems()
        let created = try XCTUnwrap(items.first)
        XCTAssertEqual(created.subject, "Планёрка (как сохранил сервер)")
    }

    /// The meeting is created either way. A fetch-back failure is not a reason to report an error.
    func testFetchBackFailureDoesNotFailTheCreation() async throws {
        let transport = ScriptedTransport([])
        await transport.setFetchResult(nil)
        let store = EASInMemorySyncStore(
            EASSyncSnapshot(
                version: EASSyncSnapshot.currentVersion,
                savedAt: Date(), collectionId: "20", syncKey: "7", filterType: 0, items: []
            )
        )
        let session = session(transport, store: store)

        try await session.createEvent(
            subject: "Планёрка", agenda: "", location: "",
            start: start, end: end,
            requiredAttendees: [], optionalAttendees: [], timeZone: moscow,
            organizerName: "Алексей",
            organizerFallbackEmail: "me@example.com"
        )

        let calls = await transport.createCalls
        XCTAssertEqual(calls.count, 1, "создание состоялось")
    }

    // MARK: The invitation

    private func warmStore(_ syncKey: String = "7") -> EASInMemorySyncStore {
        EASInMemorySyncStore(
            EASSyncSnapshot(
                version: EASSyncSnapshot.currentVersion,
                savedAt: Date(), collectionId: "20", syncKey: syncKey, filterType: 0, items: []
            )
        )
    }

    /// The whole point of the second half: without this message the meeting exists only on the
    /// organiser's calendar, which is what the widget shipped with.
    func testInvitationIsSentForAMeetingWithAttendees() async throws {
        let transport = ScriptedTransport([])
        let session = session(transport, store: warmStore())

        try await session.createEvent(
            subject: "Планёрка", agenda: "Повестка", location: "Переговорная 3",
            start: start, end: end,
            requiredAttendees: [person("Анна", "anna@example.com")],
            optionalAttendees: [person("Борис", "boris@example.com")],
            timeZone: moscow,
            organizerName: "Алексей",
            organizerFallbackEmail: "me@example.com"
        )

        let mail = await transport.sentMail
        XCTAssertEqual(mail.count, 1)
        let message = try XCTUnwrap(mail.first)
        XCTAssertTrue(message.contains("method=REQUEST"), "an invitation, not a plain mail")
        XCTAssertTrue(message.contains("<anna@example.com>"), "required attendees go to To:")
        XCTAssertTrue(message.contains("<boris@example.com>"), "optional attendees go to Cc:")
    }

    /// Exchange attributes an acceptance to a meeting by `UID`. A message carrying a different
    /// one is delivered, looks right to the attendee, and leaves the organiser's copy stuck at
    /// "no response" forever.
    func testInvitationCarriesTheUidOfTheCreatedItem() async throws {
        let transport = ScriptedTransport([])
        let session = session(transport, store: warmStore())

        try await session.createEvent(
            subject: "Планёрка", agenda: "", location: "",
            start: start, end: end,
            requiredAttendees: [person("Анна", "anna@example.com")],
            optionalAttendees: [], timeZone: moscow,
            organizerName: "Алексей",
            organizerFallbackEmail: "me@example.com"
        )

        let sent = await transport.sentMail
        let calendar = try decodedCalendarPart(XCTUnwrap(sent.first))
        XCTAssertTrue(
            calendar.contains("UID:UID-FROM-ADD"),
            "the invitation must carry the UID the Add generated, got:\n\(calendar)"
        )
    }

    /// An appointment with no attendees is not a meeting. Sending mail for it would put an
    /// invitation in the organiser's own Sent Items addressed to nobody.
    func testNoInvitationWithoutAttendees() async throws {
        let transport = ScriptedTransport([])
        let session = session(transport, store: warmStore())

        try await session.createEvent(
            subject: "Личное время", agenda: "", location: "",
            start: start, end: end,
            requiredAttendees: [], optionalAttendees: [], timeZone: moscow,
            organizerName: "Алексей",
            organizerFallbackEmail: "me@example.com"
        )

        let mail = await transport.sentMail
        XCTAssertTrue(mail.isEmpty)
    }

    /// The two halves fail independently, and the user has to be told which one did: the
    /// meeting is on the calendar and nobody was invited to it.
    func testInvitationFailureIsReportedButKeepsTheMeeting() async throws {
        let transport = ScriptedTransport([])
        await transport.setSendMailError(EASError.commandStatus(command: "SendMail", status: "150"))
        let store = warmStore()
        let session = session(transport, store: store)

        do {
            try await session.createEvent(
                subject: "Планёрка", agenda: "", location: "",
                start: start, end: end,
                requiredAttendees: [person("Анна", "anna@example.com")],
                optionalAttendees: [], timeZone: moscow,
                organizerName: "Алексей",
                organizerFallbackEmail: "me@example.com"
            )
            XCTFail("a meeting nobody was invited to must not report success")
        } catch EASError.invitationsNotSent {
            // expected
        }

        let created = await transport.createCalls
        XCTAssertEqual(created.count, 1, "the meeting was still created")
        XCTAssertEqual(store.load()?.syncKey, "7cf", "and its key advance was still persisted")
    }

    /// Asked before anything is written, so a mailbox whose address cannot be established
    /// refuses outright instead of leaving a meeting behind that nobody will hear about.
    func testMissingOrganizerAddressRefusesBeforeCreating() async throws {
        let transport = ScriptedTransport([])
        await transport.setSmtpAddress(nil)
        let session = session(transport, store: warmStore())

        do {
            try await session.createEvent(
                subject: "Планёрка", agenda: "", location: "",
                start: start, end: end,
                requiredAttendees: [person("Анна", "anna@example.com")],
                optionalAttendees: [], timeZone: moscow,
                organizerName: "Алексей",
                // What an ActiveSync login usually looks like, and not an address.
                organizerFallbackEmail: "CORP\\alexey"
            )
            XCTFail("expected the creation to refuse")
        } catch EASError.organizerAddressUnknown {
            // expected
        }

        let created = await transport.createCalls
        let sent = await transport.sentMail
        XCTAssertTrue(created.isEmpty, "nothing was written")
        XCTAssertTrue(sent.isEmpty)
    }

    /// The mailbox's own address is the server's to know: the account login can be a domain
    /// login, an alias, or an address that is not the primary one.
    func testOrganizerAddressPrefersTheServersAnswer() async throws {
        let transport = ScriptedTransport([])
        await transport.setSmtpAddress("alexey.real@example.com")
        let session = session(transport, store: warmStore())

        try await session.createEvent(
            subject: "Планёрка", agenda: "", location: "",
            start: start, end: end,
            requiredAttendees: [person("Анна", "anna@example.com")],
            optionalAttendees: [], timeZone: moscow,
            organizerName: "Алексей",
            organizerFallbackEmail: "stale-alias@example.com"
        )

        let sent = await transport.sentMail
        let calendar = try decodedCalendarPart(XCTUnwrap(sent.first))
        XCTAssertTrue(calendar.contains("MAILTO:alexey.real@example.com"))
        XCTAssertFalse(calendar.contains("stale-alias@example.com"))
    }

    /// The calendar part travels base64-encoded, so assertions about it have to decode first.
    private func decodedCalendarPart(_ message: String) throws -> String {
        let marker = "method=REQUEST"
        let afterHeader = try XCTUnwrap(message.range(of: marker))
        let rest = message[afterHeader.upperBound...]
        // Skip the part's remaining headers: a blank line separates them from the body.
        let bodyStart = try XCTUnwrap(rest.range(of: "\r\n\r\n"))
        let body = rest[bodyStart.upperBound...]
        let base64 = body
            .components(separatedBy: "\r\n")
            .prefix { !$0.hasPrefix("--") }
            .joined()
        let data = try XCTUnwrap(Data(base64Encoded: base64))
        return String(decoding: data, as: UTF8.self)
    }
}
