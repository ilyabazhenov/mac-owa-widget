import Foundation
import os.log

/// Live synchronisation state for one ActiveSync account.
///
/// This exists separately from the provider because `CalendarService.rebuildProviders()`
/// discards and rebuilds providers, while the server keeps a `SyncKey` chain per device and
/// collection that must survive that. Two sessions driving one chain would not error — they
/// would quietly split the changes between them and lose meetings.
///
/// Incrementality stops here: the provider above asks for a full window snapshot and gets one,
/// while the wire underneath carries deltas.
actor EASAccountSession {

    /// Bounds the `MoreAvailable` loop. At a window of 100 this is 5000 items, far past any
    /// real calendar — it exists so a server that never clears the flag cannot spin forever.
    private static let maxSyncRounds = 50
    private static let windowSize = 100
    /// Enough for a useful preview without carrying every agenda over the wire on each pass.
    /// The full body is a separate fetch when the detail panel asks for it.
    private static let bodyTruncationSize = 1024
    /// Generous enough for a real agenda, and only ever requested for one item at a time.
    private static let fullBodyTruncationSize = 200_000

    let accountID: UUID

    private let client: any EASSyncing
    private let store: any EASSyncStoring
    private let filterType: Int
    private let log = Logger(subsystem: "com.owawidget", category: "EASAccountSession")

    private var provisioned = false
    private var collectionId: String?
    private var syncKey = "0"
    private var items: [String: EASCalendarItem] = [:]
    private var restored = false
    private var persistedOnce = false
    private var cachedSmtpAddress: String?

    /// Coalesces concurrent callers onto one network pass.
    private var inFlight: Task<Void, Error>?

    init(
        accountID: UUID,
        client: any EASSyncing,
        store: any EASSyncStoring,
        // 5 keeps the latest month while retaining all future and unbounded recurring events.
        filterType: Int = 5
    ) {
        self.accountID = accountID
        self.client = client
        self.store = store
        self.filterType = filterType
    }

    // MARK: Public surface

    /// Brings the local copy up to date. Throws on failure rather than returning stale data:
    /// `CalendarService` owns the decision to fall back to its cache, and needs the failure to
    /// make it — and to feed the authentication breaker.
    func synchronize() async throws {
        if let existing = inFlight {
            return try await existing.value
        }
        let task = Task { try await self.runSynchronize() }
        inFlight = task
        defer { inFlight = nil }
        try await task.value
    }

    /// Everything currently known, regardless of window. Filtering and expansion happen above.
    func currentItems() -> [EASCalendarItem] {
        Array(items.values)
    }

    func item(withServerId serverId: String) -> EASCalendarItem? {
        items[serverId]
    }

    /// Answers an invitation.
    ///
    /// Needs the collection the appointment lives in, which only the session knows, and must not
    /// run while a sync is in flight — hence its place here rather than in the provider.
    func respond(
        serverId: String,
        instanceId: String?,
        response: EASMeetingResponse
    ) async throws {
        try await prepare()
        guard let collectionId else { throw EASError.calendarFolderNotFound }
        try await client.meetingResponse(
            collectionId: collectionId,
            requestId: serverId,
            instanceId: instanceId,
            response: response
        )
    }

    /// The item with its body in full, for the detail panel.
    ///
    /// Returns the cached copy when the sync already carried the whole body; only a truncated
    /// one costs a request. The fetch advances the synchronisation key, which is why it has to
    /// happen inside the session and be written back with the rest of the state.
    func fullItem(serverId: String) async throws -> EASCalendarItem? {
        // Before touching the map, not after: on a session that has not synced yet in this
        // process the items live only in the snapshot, and reading first would report every
        // meeting as unknown.
        restoreIfNeeded()
        guard let cached = items[serverId] else { return nil }
        guard cached.bodyTruncated else { return cached }

        try await prepare()
        guard let collectionId, syncKey != "0" else { return cached }

        let (newKey, fetched) = try await client.fetchItem(
            collectionId: collectionId,
            syncKey: syncKey,
            serverId: serverId,
            truncationSize: Self.fullBodyTruncationSize
        )
        syncKey = newKey
        guard var fetched else {
            persist()
            return cached
        }
        // The fetch response carries no recurrence rule, so keep what the sync established.
        fetched.recurrence = cached.recurrence
        fetched.exceptions = cached.exceptions
        items[serverId] = fetched
        persist()
        return fetched
    }

    /// Directory search. Needs a provisioned client and nothing else.
    func searchPeople(query: String, limit: Int = 50) async throws -> [ResolvedAttendee] {
        try await prepare()
        return try await client.searchGAL(query: query, limit: limit)
    }

    /// The mailbox's own address, cached for the life of the session — it does not change, and
    /// the free/busy view asks for it on every refresh.
    func smtpAddress() async throws -> String? {
        if let cachedSmtpAddress { return cachedSmtpAddress }
        try await prepare()
        let address = try await client.userSmtpAddress()
        cachedSmtpAddress = address
        return address
    }

    /// Merged free/busy strings keyed by lowercased address. Addresses the server could not
    /// resolve are simply absent; deciding what that means belongs to the caller.
    func availability(
        emails: [String],
        from start: Date,
        to end: Date
    ) async throws -> [String: String] {
        try await prepare()
        return try await client.resolveAvailability(emails: emails, from: start, to: end)
    }

    /// Creates a meeting in the calendar collection.
    ///
    /// Requires a live synchronisation key — a creation is a `Sync` like any other and advances
    /// the chain — so a cold session synchronises first rather than sending a key the server
    /// does not recognise.
    func createEvent(
        subject: String,
        agenda: String,
        location: String,
        start: Date,
        end: Date,
        requiredAttendees: [ResolvedAttendee],
        optionalAttendees: [ResolvedAttendee],
        timeZone: TimeZone
    ) async throws {
        try await prepare()
        if syncKey == "0" {
            try await runSyncRounds(allowingKeyReset: true)
        }
        guard let collectionId, syncKey != "0" else {
            throw EASError.calendarFolderNotFound
        }

        let (newKey, serverId) = try await client.createEvent(
            collectionId: collectionId,
            syncKey: syncKey,
            subject: subject,
            agenda: agenda,
            location: location,
            start: start,
            end: end,
            requiredAttendees: requiredAttendees,
            optionalAttendees: optionalAttendees,
            timeZone: timeZone
        )
        syncKey = newKey

        // The server does not send a client-created item back on the next Sync: it handed out
        // the ServerId in the Add response and considers this device to know about it already.
        // So it has to be fetched explicitly — otherwise the meeting exists on the server and
        // in OWA, but never reaches the widget until something forces a full resynchronisation.
        if let serverId {
            do {
                let (fetchedKey, created) = try await client.fetchItem(
                    collectionId: collectionId,
                    syncKey: syncKey,
                    serverId: serverId,
                    truncationSize: Self.bodyTruncationSize
                )
                syncKey = fetchedKey
                if let created {
                    items[serverId] = created
                } else {
                    // The server did not return the item. There may be several reasons, and
                    // investigating them retrospectively is costly; the result is the same:
                    // the meeting exists on the server but not in the widget until a full resync.
                    //
                    // We know exactly what we sent, so we can build the item ourselves.
                    // The next sync that touches it will replace this version with the server's.
                    items[serverId] = EASCalendarItem(
                        serverId: serverId,
                        locallyCreated: subject,
                        location: location,
                        start: start,
                        end: end,
                        agenda: agenda,
                        requiredAttendees: requiredAttendees,
                        optionalAttendees: optionalAttendees
                    )
                    DiagnosticLog.event("EAS created event rebuilt locally serverId=\(serverId)")
                }
            } catch {
                // The meeting is created either way; failing here would report an error for
                // work that succeeded. It will appear on the next full resynchronisation.
                DiagnosticLog.event("EAS created event fetch-back failed")
            }
        }

        persist()
        // Plaintext on purpose: otherwise the only evidence that the meeting was created stays
        // in an unread log channel. ServerId identifies the server item, not meeting content.
        DiagnosticLog.event("EAS created event serverId=\(serverId ?? "none") attendees=\(requiredAttendees.count + optionalAttendees.count)")
    }

    /// Provisioning and folder resolution, shared by every operation that needs them.
    private func prepare() async throws {
        restoreIfNeeded()
        if !provisioned {
            try await client.provision()
            provisioned = true
        }
        if collectionId == nil {
            collectionId = try await client.defaultCalendarFolder().id
        }
    }

    // MARK: Synchronisation

    private func runSynchronize() async throws {
        try await prepare()

        do {
            try await runSyncRounds(allowingKeyReset: true)
        } catch let error as EASError {
            // The folder hierarchy moved underneath us: re-resolve and let the next pass run.
            if case .commandStatus(let command, let status) = error,
               command == "FolderSync" || status == "12" {
                collectionId = nil
                throw error
            }
            throw error
        }
    }

    private func runSyncRounds(allowingKeyReset: Bool) async throws {
        guard let collectionId else {
            throw EASError.calendarFolderNotFound
        }

        do {
            // A chain starts with a round that carries no data and only yields a usable key.
            if syncKey == "0" {
                let primed = try await client.sync(
                    collectionId: collectionId,
                    syncKey: "0",
                    windowSize: Self.windowSize,
                    filterType: filterType,
                    bodyTruncationSize: Self.bodyTruncationSize
                )
                syncKey = primed.syncKey
                items.removeAll()
            }

            var rounds = 0
            var changed = false
            while rounds < Self.maxSyncRounds {
                rounds += 1
                let result = try await client.sync(
                    collectionId: collectionId,
                    syncKey: syncKey,
                    windowSize: Self.windowSize,
                    filterType: filterType,
                    bodyTruncationSize: Self.bodyTruncationSize
                )
                syncKey = result.syncKey
                for item in result.upserted { items[item.serverId] = item }
                for id in result.deletedIds { items.removeValue(forKey: id) }
                if !result.upserted.isEmpty || !result.deletedIds.isEmpty { changed = true }

                if !result.moreAvailable { break }
                if rounds == Self.maxSyncRounds {
                    log.error("EAS sync hit the round cap with more changes pending")
                }
            }

            // Rewrite the snapshot only when items actually changed.
            //
            // Most timer passes bring no changes, while writing encrypts and persists the whole
            // calendar — thousands of items every five minutes for a mature mailbox, for nothing.
            //
            // Skipping the write is safe: disk retains an atomically captured, consistent
            // “key + items” pair. After restart, sync resumes from that key and the server
            // repeats exactly the changes that were absent — none.
            if changed || !persistedOnce {
                persist()
                persistedOnce = true
            }
            DiagnosticLog.event("EAS sync done items=\(items.count) rounds=\(rounds) changed=\(changed)")

        } catch EASError.commandStatus(command: "Sync", status: "3") where allowingKeyReset {
            // The server no longer recognises the key. Anything it sends next would be a delta
            // against a baseline we do not share, so the local copy goes too.
            log.warning("EAS SyncKey rejected; restarting the chain from scratch")
            syncKey = "0"
            items.removeAll()
            store.clear()
            try await runSyncRounds(allowingKeyReset: false)
        }
    }

    // MARK: Persistence

    private func restoreIfNeeded() {
        guard !restored else { return }
        restored = true

        guard let snapshot = store.load() else { return }
        // A filter change redefines what the server considers in scope, which invalidates the
        // key it issued under the old one.
        guard snapshot.filterType == filterType else {
            log.info("EAS snapshot discarded: filter changed")
            store.clear()
            return
        }

        collectionId = snapshot.collectionId
        syncKey = snapshot.syncKey
        items = Dictionary(uniqueKeysWithValues: snapshot.items.map { ($0.serverId, $0) })
        // The snapshot was restored, so disk already contains a consistent “key + items” pair;
        // a pass without changes does not need to rewrite it.
        persistedOnce = true
        log.info("EAS snapshot restored with \(self.items.count, privacy: .public) items")
    }

    private func persist() {
        guard let collectionId else { return }
        store.save(
            EASSyncSnapshot(
                version: EASSyncSnapshot.currentVersion,
                savedAt: Date(),
                collectionId: collectionId,
                syncKey: syncKey,
                filterType: filterType,
                items: Array(items.values)
            )
        )
    }
}
