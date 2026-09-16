import Foundation
import os.log

/// Calendar provider backed by Exchange ActiveSync.
///
/// Same mailbox as ``OWACalendarProvider``, different protocol. The point of the exercise is
/// reachability: ActiveSync answers on a single published endpoint, so this provider keeps
/// working with the VPN off.
actor EASCalendarProvider: CalendarProvider {

    nonisolated let account: CalendarAccount

    private let host: String
    private let password: String
    private let mapper = EASCalendarMapper()
    private let log = Logger(subsystem: "com.owawidget", category: "EASCalendarProvider")

    init(account: CalendarAccount, password: String) throws {
        self.account = account
        self.password = password

        // Reuse the OWA URL parser so both account types agree on what a server address is:
        // it forces https, tolerates a bare hostname, and rejects everything else.
        let base = try OWAClient.parseBaseURL(account.serverURL)
        guard let host = base.host, !host.isEmpty else {
            throw OWAError.invalidURL(account.serverURL)
        }
        self.host = host

        // Fail here rather than mid-sync if the stored device identifier is unreadable:
        // minting a replacement would register a second device with Exchange.
        _ = try EASDeviceIdentity.deviceId(for: account.id)
    }

    // MARK: Client construction

    private nonisolated func makeClient(deviceId: String) -> EASClient {
        EASClient(
            EASClient.Configuration(
                host: host,
                username: account.email,
                password: password,
                deviceId: deviceId,
                device: account.resolvedDeviceProfile
            )
        )
    }

    /// The registry-held session for this account, created on first use.
    private func currentSession() async throws -> EASAccountSession {
        try await EASSessionRegistry.shared.session(
            for: account,
            password: password,
            makeClient: { [self] deviceId in makeClient(deviceId: deviceId) }
        )
    }

    // MARK: CalendarProvider

    /// Proves the whole chain, not just that the host answered: OPTIONS for reachability and
    /// credentials, Provision for policy acceptance, FolderSync for a calendar to read.
    ///
    /// Four requests rather than one is deliberate. A test that only checked OPTIONS would pass
    /// on a mailbox with ActiveSync disabled, and the user would find out later as an empty
    /// calendar. A wrong password still costs a single attempt: the client latches on the first
    /// 401 and the rest of the chain never reaches the network.
    ///
    /// Runs on its own client rather than the shared session, because the account being tested
    /// may not be saved yet and has no business owning a synchronisation chain.
    func validateCredentials() async throws {
        do {
            let deviceId = try EASDeviceIdentity.deviceId(for: account.id)
            let client = makeClient(deviceId: deviceId)

            let capabilities = try await client.capabilities()
            log.info("EAS server \(capabilities.server, privacy: .public), versions \(capabilities.protocolVersions, privacy: .public)")

            try await client.provision()
            let calendar = try await client.defaultCalendarFolder()
            log.info("EAS calendar folder resolved (type \(calendar.type, privacy: .public))")
        } catch {
            throw EASErrorBridge.owaError(from: error, context: "validateCredentials")
        }
    }

    /// The full window, every time — which is what `CalendarService` expects. Underneath, the
    /// session has only fetched what changed.
    ///
    /// A synchronisation failure is rethrown rather than answered with the stale local copy.
    /// Swallowing it would look like a successful sync: the status would claim `lastSynced`,
    /// the offline cache would be overwritten, the breaker would never see the failure, and the
    /// user would not learn they are disconnected.
    func fetchEvents(from start: Date, to end: Date) async throws -> [CalendarEvent] {
        do {
            let session = try await currentSession()
            try await session.synchronize()

            let items = await session.currentItems()
            let accountID = account.id
            let window = DateInterval(start: start, end: end)

            // A series arrives as one master plus its exceptions, never as occurrences, so the
            // expander produces them here. Filtering to the window happens inside it, since a
            // rule can generate far more than the window holds.
            let events = items.flatMap { item in
                mapper.events(from: item, in: window, accountID: accountID, fallbackZone: AppTimeZone.zone)
            }

            let series = items.filter(\.isRecurring).count
            log.info("EAS window produced \(events.count, privacy: .public) events from \(items.count, privacy: .public) items (\(series, privacy: .public) series)")
            return events.sorted { $0.startDate < $1.startDate }
        } catch {
            throw EASErrorBridge.owaError(from: error, context: "fetchEvents")
        }
    }

    /// Answers an invitation.
    ///
    /// `changeKey` carries the appointment's ActiveSync `ServerId` — see the mapper — and
    /// `instanceKey` narrows the answer to one occurrence when the event came from a series.
    /// Without it the whole series would be answered, which is a different thing entirely.
    func respondToMeeting(_ event: CalendarEvent, action: MeetingResponseAction) async throws {
        do {
            guard let serverId = event.changeKey, !serverId.isEmpty else {
                throw CalendarProviderError.notSupported
            }
            let session = try await currentSession()
            try await session.respond(
                serverId: serverId,
                instanceId: event.instanceKey,
                response: EASMeetingResponse(action)
            )
            DiagnosticLog.event("EAS meeting response sent occurrence=\(event.instanceKey != nil)")
        } catch {
            throw EASErrorBridge.owaError(from: error, context: "respondToMeeting")
        }
    }

    /// Attendees and the full agenda.
    ///
    /// Usually free: the sync already carried both, capped at a preview length. Only a body the
    /// server truncated costs a request.
    func fetchDetails(for event: CalendarEvent) async throws -> CalendarEventDetails {
        do {
            guard let serverId = event.changeKey, !serverId.isEmpty else {
                throw CalendarProviderError.notSupported
            }
            let session = try await currentSession()
            guard let item = try await session.fullItem(serverId: serverId) else {
                // The event predates the current local copy — nothing to expand on.
                throw CalendarProviderError.notSupported
            }
            return EASCalendarMapper.details(from: item, instanceKey: event.instanceKey)
        } catch {
            throw EASErrorBridge.owaError(from: error, context: "fetchDetails")
        }
    }

    // MARK: People and availability

    /// Directory search.
    ///
    /// Mirrors the OWA provider's fallback: a multi-word query that the server answers with
    /// nothing is retried on its longest token and filtered locally. Directories routinely fail
    /// to match "Ivan Petrov" as a phrase while matching either half — without this, searching
    /// by full name simply returns nothing.
    func findPeople(query: String) async throws -> [ResolvedAttendee] {
        do {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return [] }

            let session = try await currentSession()
            let direct = try await session.searchPeople(query: trimmed)
            if !direct.isEmpty { return direct }

            guard let token = EASPeopleSearch.fallbackToken(for: trimmed) else { return direct }
            let broadened = try await session.searchPeople(query: token)
            return EASPeopleSearch.narrow(broadened, query: trimmed, searchedToken: token)
        } catch {
            throw EASErrorBridge.owaError(from: error, context: "findPeople")
        }
    }

    /// The mailbox's own address. The account login is `DOMAIN\user`, which is not one.
    func resolveOrganizerSMTPEmail() async throws -> String? {
        do {
            return try await currentSession().smtpAddress()
        } catch {
            throw EASErrorBridge.owaError(from: error, context: "resolveOrganizerSMTPEmail")
        }
    }

    /// Merged free/busy, one row per requested address, in the order they were asked for.
    ///
    /// The positional guarantee is a hard requirement, not a convenience: `ColleaguePresenceService`
    /// checks `rows.count == emails.count` and treats a mismatch as a failed refresh. The server
    /// is free to omit an address it could not resolve, so gaps are filled with a "no data" row
    /// rather than shifting every later colleague onto someone else's schedule.
    func getUserAvailability(
        emails: [String],
        from start: Date,
        to end: Date
    ) async throws -> [AttendeeAvailability] {
        do {
            guard !emails.isEmpty else { return [] }
            let session = try await currentSession()
            let byAddress = try await session.availability(emails: emails, from: start, to: end)
            return EASPeopleSearch.availabilityRows(
                emails: emails, merged: byAddress, from: start, to: end
            )
        } catch {
            throw EASErrorBridge.owaError(from: error, context: "getUserAvailability")
        }
    }


    // MARK: Creating a meeting

    /// Creates a meeting and lets the server send the invitations.
    ///
    /// The created event is not inserted locally: `CalendarService` triggers a sync straight
    /// after this returns, and the version the server stored — with whatever it normalised — is
    /// the one the rest of the app should see.
    func createMeeting(
        title: String,
        agenda: String,
        location: String,
        start: Date,
        end: Date,
        requiredAttendees: [ResolvedAttendee],
        optionalAttendees: [ResolvedAttendee]
    ) async throws {
        do {
            let session = try await currentSession()
            try await session.createEvent(
                subject: title,
                agenda: agenda,
                location: location,
                start: start,
                end: end,
                requiredAttendees: requiredAttendees,
                optionalAttendees: optionalAttendees,
                timeZone: AppTimeZone.zone
            )
        } catch {
            throw EASErrorBridge.owaError(from: error, context: "createMeeting")
        }
    }
}
