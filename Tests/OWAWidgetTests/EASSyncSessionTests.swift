import XCTest
@testable import OWAWidget

/// Drives ``EASAccountSession`` with a scripted transport.
///
/// Every invariant here fails silently in production when broken — a missed priming round,
/// a `MoreAvailable` loop that stops early, a rejected key that resets without discarding the
/// local items — so none of it can be left to the live server to reveal.
actor ScriptedTransport: EASSyncing {

    enum Step {
        case result(EASSyncResult)
        case failure(Error)
    }

    private var script: [Step]
    private(set) var provisionCount = 0
    private(set) var folderCount = 0
    private(set) var syncKeysRequested: [String] = []

    init(_ script: [Step]) { self.script = script }

    func provision() async throws { provisionCount += 1 }

    func defaultCalendarFolder() async throws -> EASFolder {
        folderCount += 1
        return EASFolder(id: "20", displayName: "Calendar", type: 8)
    }

    func sync(
        collectionId: String,
        syncKey: String,
        windowSize: Int,
        filterType: Int,
        bodyTruncationSize: Int
    ) async throws -> EASSyncResult {
        syncKeysRequested.append(syncKey)
        guard !script.isEmpty else {
            return EASSyncResult(syncKey: syncKey, moreAvailable: false, upserted: [], deletedIds: [])
        }
        switch script.removeFirst() {
        case .result(let result): return result
        case .failure(let error): throw error
        }
    }

    // MARK: Recorded writes

    struct RespondCall: Equatable {
        let collectionId: String
        let requestId: String
        let instanceId: String?
        let response: EASMeetingResponse
    }

    private(set) var respondCalls: [RespondCall] = []
    private(set) var fetchedServerIds: [String] = []
    var respondError: Error?
    var fetchResult: EASCalendarItem?

    func setRespondError(_ error: Error?) { respondError = error }
    func setFetchResult(_ item: EASCalendarItem?) { fetchResult = item }

    func meetingResponse(
        collectionId: String,
        requestId: String,
        instanceId: String?,
        response: EASMeetingResponse
    ) async throws {
        respondCalls.append(
            RespondCall(
                collectionId: collectionId,
                requestId: requestId,
                instanceId: instanceId,
                response: response
            )
        )
        if let respondError { throw respondError }
    }

    func fetchItem(
        collectionId: String,
        syncKey: String,
        serverId: String,
        truncationSize: Int
    ) async throws -> (syncKey: String, item: EASCalendarItem?) {
        fetchedServerIds.append(serverId)
        return (syncKey + "f", fetchResult)
    }

    // MARK: Directory and availability

    private(set) var searchQueries: [String] = []
    private(set) var smtpCalls = 0
    private(set) var availabilityRequests: [[String]] = []

    var searchResults: [String: [ResolvedAttendee]] = [:]
    var smtpAddress: String?
    var availabilityByAddress: [String: String] = [:]

    func setSearchResults(_ results: [String: [ResolvedAttendee]]) { searchResults = results }
    func setSmtpAddress(_ address: String?) { smtpAddress = address }
    func setAvailability(_ map: [String: String]) { availabilityByAddress = map }

    func searchGAL(query: String, limit: Int) async throws -> [ResolvedAttendee] {
        searchQueries.append(query)
        return searchResults[query] ?? []
    }

    func userSmtpAddress() async throws -> String? {
        smtpCalls += 1
        return smtpAddress
    }

    func resolveAvailability(
        emails: [String],
        from start: Date,
        to end: Date
    ) async throws -> [String: String] {
        availabilityRequests.append(emails)
        return availabilityByAddress
    }

    // MARK: Creation

    struct CreateCall: Equatable {
        let collectionId: String
        let syncKey: String
        let subject: String
        let required: [String]
        let optional: [String]
    }

    private(set) var createCalls: [CreateCall] = []
    var createError: Error?

    func setCreateError(_ error: Error?) { createError = error }

    func createEvent(
        collectionId: String,
        syncKey: String,
        subject: String,
        agenda: String,
        location: String,
        start: Date,
        end: Date,
        requiredAttendees: [ResolvedAttendee],
        optionalAttendees: [ResolvedAttendee],
        timeZone: TimeZone
    ) async throws -> (syncKey: String, serverId: String?) {
        createCalls.append(
            CreateCall(
                collectionId: collectionId,
                syncKey: syncKey,
                subject: subject,
                required: requiredAttendees.map(\.email),
                optional: optionalAttendees.map(\.email)
            )
        )
        if let createError { throw createError }
        return (syncKey + "c", "20:new")
    }
}

func makeItem(_ id: String, subject: String = "Standup") -> EASCalendarItem {
    EASCalendarItem(
        serverId: id,
        subject: subject,
        location: nil,
        start: Date(timeIntervalSince1970: 1_800_000_000),
        end: Date(timeIntervalSince1970: 1_800_001_800),
        isAllDay: false,
        organizerName: "Ivan",
        organizerEmail: "ivan@example.com",
        attendees: [],
        categories: [],
        uid: nil,
        meetingStatus: 1,
        responseType: nil,
        busyStatus: 2,
        bodyText: nil,
        bodyTruncated: false,
        onlineMeetingConfLink: nil,
        onlineMeetingExternalLink: nil,
        timezone: nil,
        recurrence: nil,
        exceptions: []
    )
}

final class EASSyncSessionTests: XCTestCase {

    private let accountID = UUID()

    private func makeSession(
        transport: ScriptedTransport,
        store: any EASSyncStoring = EASInMemorySyncStore(),
        filterType: Int = 0
    ) -> EASAccountSession {
        EASAccountSession(accountID: accountID, client: transport, store: store, filterType: filterType)
    }

    // MARK: The priming round

    /// A chain must open with a `SyncKey=0` round, and that round never carries items. Treating
    /// its empty answer as "the calendar is empty" would show nothing until something changed.
    func testFirstSyncPrimesThenFetches() async throws {
        let transport = ScriptedTransport([
            .result(EASSyncResult(syncKey: "1", moreAvailable: false, upserted: [], deletedIds: [])),
            .result(EASSyncResult(syncKey: "2", moreAvailable: false, upserted: [makeItem("20:1")], deletedIds: [])),
        ])
        let session = makeSession(transport: transport)

        try await session.synchronize()

        let requested = await transport.syncKeysRequested
        let items = await session.currentItems()
        let provisions = await transport.provisionCount
        let folders = await transport.folderCount

        XCTAssertEqual(requested, ["0", "1"], "priming round, then the real one")
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(provisions, 1)
        XCTAssertEqual(folders, 1)
    }

    func testFollowsMoreAvailableUntilItClears() async throws {
        let transport = ScriptedTransport([
            .result(EASSyncResult(syncKey: "1", moreAvailable: false, upserted: [], deletedIds: [])),
            .result(EASSyncResult(syncKey: "2", moreAvailable: true, upserted: [makeItem("20:1")], deletedIds: [])),
            .result(EASSyncResult(syncKey: "3", moreAvailable: true, upserted: [makeItem("20:2")], deletedIds: [])),
            .result(EASSyncResult(syncKey: "4", moreAvailable: false, upserted: [makeItem("20:3")], deletedIds: [])),
        ])
        let session = makeSession(transport: transport)

        try await session.synchronize()

        let requested = await transport.syncKeysRequested
        let items = await session.currentItems()
        XCTAssertEqual(requested, ["0", "1", "2", "3"])
        XCTAssertEqual(items.count, 3)
    }

    func testDeletionsRemoveItems() async throws {
        let transport = ScriptedTransport([
            .result(EASSyncResult(syncKey: "1", moreAvailable: false, upserted: [], deletedIds: [])),
            .result(EASSyncResult(syncKey: "2", moreAvailable: false,
                                  upserted: [makeItem("20:1"), makeItem("20:2")], deletedIds: [])),
        ])
        let session = makeSession(transport: transport)
        try await session.synchronize()
        let initial = await session.currentItems()
        XCTAssertEqual(initial.count, 2)

        // A second pass carrying only a delete.
        let removal = ScriptedTransport([
            .result(EASSyncResult(syncKey: "3", moreAvailable: false, upserted: [], deletedIds: ["20:1"])),
        ])
        let store = EASInMemorySyncStore(
            EASSyncSnapshot(
                version: EASSyncSnapshot.currentVersion,
                savedAt: Date(),
                collectionId: "20",
                syncKey: "2",
                filterType: 0,
                items: [makeItem("20:1"), makeItem("20:2")]
            )
        )
        let resumed = makeSession(transport: removal, store: store)
        try await resumed.synchronize()

        let remaining = await resumed.currentItems().map(\.serverId)
        XCTAssertEqual(remaining, ["20:2"])
    }

    // MARK: A rejected key

    /// `Status=3` means the server forgot the key. Everything it sends afterwards is a delta
    /// against a baseline we no longer share, so the local copy has to go with it — keeping the
    /// items would leave stale meetings that never disappear.
    func testRejectedSyncKeyRestartsAndDiscardsLocalItems() async throws {
        let store = EASInMemorySyncStore(
            EASSyncSnapshot(
                version: EASSyncSnapshot.currentVersion,
                savedAt: Date(),
                collectionId: "20",
                syncKey: "99",
                filterType: 0,
                items: [makeItem("20:stale", subject: "Cancelled long ago")]
            )
        )
        let transport = ScriptedTransport([
            .failure(EASError.commandStatus(command: "Sync", status: "3")),
            .result(EASSyncResult(syncKey: "1", moreAvailable: false, upserted: [], deletedIds: [])),
            .result(EASSyncResult(syncKey: "2", moreAvailable: false, upserted: [makeItem("20:fresh")], deletedIds: [])),
        ])
        let session = makeSession(transport: transport, store: store)

        try await session.synchronize()

        let requested = await transport.syncKeysRequested
        XCTAssertEqual(requested, ["99", "0", "1"],
                       "the rejected key, then a fresh chain from zero")
        let ids = await session.currentItems().map(\.serverId)
        XCTAssertEqual(ids, ["20:fresh"], "the stale item must not survive the reset")
    }

    /// The reset is allowed once. A server that rejects the fresh key too must surface the
    /// error rather than keep the session looping.
    func testRepeatedKeyRejectionGivesUp() async throws {
        let transport = ScriptedTransport([
            .failure(EASError.commandStatus(command: "Sync", status: "3")),
            .failure(EASError.commandStatus(command: "Sync", status: "3")),
            .failure(EASError.commandStatus(command: "Sync", status: "3")),
        ])
        let session = makeSession(transport: transport)

        do {
            try await session.synchronize()
            XCTFail("expected the second rejection to propagate")
        } catch {
            guard case EASError.commandStatus(command: "Sync", status: "3") = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
        let attempts = await transport.syncKeysRequested.count
        XCTAssertLessThanOrEqual(attempts, 3, "one reset, not an endless retry")
    }

    // MARK: Failures reach the caller

    /// The session holds a usable local copy, which makes returning it on failure tempting.
    /// It must not: `CalendarService` owns the offline decision and needs the throw to make it,
    /// and the authentication breaker only counts failures it is told about.
    func testSynchronizeRethrowsInsteadOfServingStaleItems() async throws {
        let store = EASInMemorySyncStore(
            EASSyncSnapshot(
                version: EASSyncSnapshot.currentVersion,
                savedAt: Date(),
                collectionId: "20",
                syncKey: "5",
                filterType: 0,
                items: [makeItem("20:1")]
            )
        )
        let transport = ScriptedTransport([.failure(EASError.authenticationRejected)])
        let session = makeSession(transport: transport, store: store)

        do {
            try await session.synchronize()
            XCTFail("expected the authentication failure to propagate")
        } catch {
            guard case EASError.authenticationRejected = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
        // The local copy stays available for whoever asks explicitly — it just is not a
        // substitute for reporting the failure.
        let retained = await session.currentItems()
        XCTAssertEqual(retained.count, 1)
    }

    // MARK: Snapshot handling

    func testRestoredSnapshotSkipsThePrimingRound() async throws {
        let store = EASInMemorySyncStore(
            EASSyncSnapshot(
                version: EASSyncSnapshot.currentVersion,
                savedAt: Date(),
                collectionId: "20",
                syncKey: "7",
                filterType: 0,
                items: [makeItem("20:1")]
            )
        )
        let transport = ScriptedTransport([
            .result(EASSyncResult(syncKey: "8", moreAvailable: false, upserted: [], deletedIds: [])),
        ])
        let session = makeSession(transport: transport, store: store)

        try await session.synchronize()

        let requested = await transport.syncKeysRequested
        let folders = await transport.folderCount
        XCTAssertEqual(requested, ["7"], "resumed, not restarted")
        XCTAssertEqual(folders, 0, "the collection id came from the snapshot")
    }

    /// The filter decides what the server considers in scope, so the key it issued under the
    /// old one describes a different set. Resuming with it would leave a permanent hole.
    func testSnapshotFromADifferentFilterIsDiscarded() async throws {
        let store = EASInMemorySyncStore(
            EASSyncSnapshot(
                version: EASSyncSnapshot.currentVersion,
                savedAt: Date(),
                collectionId: "20",
                syncKey: "7",
                filterType: 5,
                items: [makeItem("20:1")]
            )
        )
        let transport = ScriptedTransport([
            .result(EASSyncResult(syncKey: "1", moreAvailable: false, upserted: [], deletedIds: [])),
            .result(EASSyncResult(syncKey: "2", moreAvailable: false, upserted: [], deletedIds: [])),
        ])
        let session = makeSession(transport: transport, store: store, filterType: 0)

        try await session.synchronize()

        let requested = await transport.syncKeysRequested
        XCTAssertEqual(requested.first, "0", "restarted from scratch")
        XCTAssertNil(store.load().map(\.filterType).flatMap { $0 == 5 ? 5 : nil })
    }

    func testSnapshotIsWrittenWithKeyAndItemsTogether() async throws {
        let store = EASInMemorySyncStore()
        let transport = ScriptedTransport([
            .result(EASSyncResult(syncKey: "1", moreAvailable: false, upserted: [], deletedIds: [])),
            .result(EASSyncResult(syncKey: "2", moreAvailable: false, upserted: [makeItem("20:1")], deletedIds: [])),
        ])
        let session = makeSession(transport: transport, store: store)

        try await session.synchronize()

        let saved = try XCTUnwrap(store.load())
        XCTAssertEqual(saved.syncKey, "2")
        XCTAssertEqual(saved.items.count, 1, "a key without its items would strand the chain")
        XCTAssertEqual(saved.collectionId, "20")
        XCTAssertEqual(saved.filterType, 0)
    }

    // MARK: Concurrency

    /// Two callers arriving together must share one pass. Two chains advancing the same server
    /// key would split the changes between them and lose the rest.
    func testConcurrentCallersShareOneSyncPass() async throws {
        let transport = ScriptedTransport([
            .result(EASSyncResult(syncKey: "1", moreAvailable: false, upserted: [], deletedIds: [])),
            .result(EASSyncResult(syncKey: "2", moreAvailable: false, upserted: [makeItem("20:1")], deletedIds: [])),
        ])
        let session = makeSession(transport: transport)

        async let first: Void = session.synchronize()
        async let second: Void = session.synchronize()
        _ = try await (first, second)

        let provisions = await transport.provisionCount
        let requested = await transport.syncKeysRequested
        XCTAssertEqual(provisions, 1, "provisioned once, not twice")
        XCTAssertEqual(requested, ["0", "1"])
    }

    // MARK: Snapshot write optimization

    /// A timer pass without changes must not re-encrypt the entire calendar.
    /// Skipping the write is safe: disk keeps a consistent “key + items” pair, and after restart
    /// the server repeats exactly the changes that were not present.
    func testUnchangedSyncDoesNotRewriteTheSnapshot() async throws {
        let store = EASInMemorySyncStore(
            EASSyncSnapshot(
                version: EASSyncSnapshot.currentVersion,
                savedAt: Date(timeIntervalSince1970: 1_000),
                collectionId: "20",
                syncKey: "5",
                filterType: 0,
                items: [makeItem("20:1")]
            )
        )
        let transport = ScriptedTransport([
            .result(EASSyncResult(syncKey: "6", moreAvailable: false, upserted: [], deletedIds: [])),
        ])
        let session = makeSession(transport: transport, store: store)

        try await session.synchronize()

        let saved = try XCTUnwrap(store.load())
        XCTAssertEqual(saved.syncKey, "5", "ключ на диске остался прежним — вместе со своими элементами")
        XCTAssertEqual(saved.savedAt, Date(timeIntervalSince1970: 1_000), "снимок не переписан")
    }

    func testChangedSyncDoesRewriteTheSnapshot() async throws {
        let store = EASInMemorySyncStore(
            EASSyncSnapshot(
                version: EASSyncSnapshot.currentVersion,
                savedAt: Date(timeIntervalSince1970: 1_000),
                collectionId: "20",
                syncKey: "5",
                filterType: 0,
                items: [makeItem("20:1")]
            )
        )
        let transport = ScriptedTransport([
            .result(EASSyncResult(syncKey: "6", moreAvailable: false, upserted: [makeItem("20:2")], deletedIds: [])),
        ])
        let session = makeSession(transport: transport, store: store)

        try await session.synchronize()

        let saved = try XCTUnwrap(store.load())
        XCTAssertEqual(saved.syncKey, "6")
        XCTAssertEqual(saved.items.count, 2)
    }

    /// The first successful pass must persist even without changes; otherwise `collectionId` and
    /// the working key do not survive restart, forcing a full resynchronization.
    func testFirstSyncPersistsEvenWithoutChanges() async throws {
        let store = EASInMemorySyncStore()
        let transport = ScriptedTransport([
            .result(EASSyncResult(syncKey: "1", moreAvailable: false, upserted: [], deletedIds: [])),
            .result(EASSyncResult(syncKey: "2", moreAvailable: false, upserted: [], deletedIds: [])),
        ])
        let session = makeSession(transport: transport, store: store)

        try await session.synchronize()

        let saved = try XCTUnwrap(store.load())
        XCTAssertEqual(saved.syncKey, "2")
        XCTAssertEqual(saved.collectionId, "20")
    }
}
