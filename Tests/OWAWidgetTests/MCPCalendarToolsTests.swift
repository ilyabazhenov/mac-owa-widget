import XCTest
@testable import OWAWidget

/// The MCP tools over a real `CalendarService` with fake providers: no Keychain, no EventKit,
/// no network. Time is fixed at Monday 2026-10-05 12:00 Moscow.
@MainActor
final class MCPCalendarToolsTests: XCTestCase {
    private actor DetailsProvider: CalendarProvider {
        nonisolated let account: CalendarAccount
        private let attendeesByID: [String: [EventAttendee]]
        private let uidByID: [String: String]
        private let error: Error?
        private let people: [ResolvedAttendee]
        private let ownEmail: String?
        private let ownEmailError: Error?
        /// Free/busy character per 30-minute interval start; a mailbox missing here gets no row,
        /// as when Exchange has nothing for it.
        private let busy: [String: @Sendable (Date) -> Character]
        private(set) var detailCalls: [String] = []
        private(set) var ownEmailCalls = 0
        private(set) var peopleSearches: [String] = []
        private let failingSearches: Set<String>
        /// Meetings beyond the sync window, returned by `fetchEvents` when they overlap the range.
        private let archive: [CalendarEvent]
        private let fetchError: Error?
        private let fetchDelay: Duration?
        private(set) var fetchCalls: [DateInterval] = []
        private(set) var created: [(title: String, start: Date, required: [String], optional: [String])] = []
        private(set) var removed: [(id: String, mode: MeetingRemovalMode, message: String)] = []
        private let removeError: Error?
        /// Organization charts by lowercased address; a missing address is "not in the address book".
        private let org: [String: OrgHierarchy]
        private let failingOrg: Set<String>
        private(set) var orgCalls: [String] = []
        private let profiles: [String: PersonProfile]
        private let failingProfiles: Set<String>
        private(set) var profileCalls: [String] = []

        init(
            account: CalendarAccount,
            attendeesByID: [String: [EventAttendee]] = [:],
            uidByID: [String: String] = [:],
            error: Error? = nil,
            people: [ResolvedAttendee] = [],
            ownEmail: String? = nil,
            ownEmailError: Error? = nil,
            busy: [String: @Sendable (Date) -> Character] = [:],
            failingSearches: Set<String> = [],
            archive: [CalendarEvent] = [],
            fetchError: Error? = nil,
            fetchDelay: Duration? = nil,
            removeError: Error? = nil,
            org: [String: OrgHierarchy] = [:],
            failingOrg: Set<String> = [],
            profiles: [String: PersonProfile] = [:],
            failingProfiles: Set<String> = []
        ) {
            self.account = account
            self.org = org
            self.failingOrg = failingOrg
            self.profiles = profiles
            self.failingProfiles = failingProfiles
            self.removeError = removeError
            self.attendeesByID = attendeesByID
            self.uidByID = uidByID
            self.error = error
            self.people = people
            self.ownEmail = ownEmail
            self.ownEmailError = ownEmailError
            self.busy = busy
            self.failingSearches = failingSearches
            self.archive = archive
            self.fetchError = fetchError
            self.fetchDelay = fetchDelay
        }

        func getUserAvailability(emails: [String], from start: Date, to end: Date) async throws -> [AttendeeAvailability] {
            emails.compactMap { email in
                guard let state = busy[email] else { return nil }
                let count = Int(end.timeIntervalSince(start) / 1800)
                let merged = String((0..<count).map { state(start.addingTimeInterval(Double($0) * 1800)) })
                return AttendeeAvailability(email: email, mergedFreeBusy: merged, windowStart: start, intervalMinutes: 30)
            }
        }

        func findPeople(query: String) async throws -> [ResolvedAttendee] {
            peopleSearches.append(query)
            if failingSearches.contains(query) { throw URLError(.badServerResponse) }
            return people.filter { $0.displayName.localizedCaseInsensitiveContains(query) || $0.email.contains(query.lowercased()) }
        }

        func organizationHierarchy(email: String) async throws -> OrgHierarchy? {
            orgCalls.append(email)
            if failingOrg.contains(email) { throw URLError(.badServerResponse) }
            return org[email.lowercased()]
        }

        func personProfile(email: String) async throws -> PersonProfile? {
            profileCalls.append(email)
            if failingProfiles.contains(email) { throw URLError(.badServerResponse) }
            return profiles[email.lowercased()]
        }

        func resolveOrganizerSMTPEmail() async throws -> String? {
            ownEmailCalls += 1
            if let ownEmailError { throw ownEmailError }
            return ownEmail
        }

        func createMeeting(
            title: String,
            agenda: RichText,
            location: String,
            start: Date,
            end: Date,
            requiredAttendees: [ResolvedAttendee],
            optionalAttendees: [ResolvedAttendee]
        ) async throws {
            created.append((title, start, requiredAttendees.map(\.email), optionalAttendees.map(\.email)))
        }

        func removeMeeting(_ event: CalendarEvent, mode: MeetingRemovalMode, message: String) async throws {
            if let removeError { throw removeError }
            removed.append((event.id, mode, message))
        }

        private(set) var responses: [(id: String, action: MeetingResponseAction, series: Bool, notes: String, send: Bool)] = []
        func respondToCalendarEvent(_ event: CalendarEvent, action: MeetingResponseAction, series: Bool, notes: String, sendResponse: Bool) async throws {
            if let removeError { throw removeError }
            responses.append((event.id, action, series, notes, sendResponse))
        }

        func fetchEvents(from start: Date, to end: Date) async throws -> [CalendarEvent] {
            fetchCalls.append(DateInterval(start: start, end: end))
            if let fetchDelay { try await Task.sleep(for: fetchDelay) }
            if let fetchError { throw fetchError }
            return archive.filter { $0.startDate < end && $0.endDate > start }
        }
        func validateCredentials() async throws {}

        func fetchDetails(for event: CalendarEvent) async throws -> CalendarEventDetails {
            detailCalls.append(event.id)
            if let error { throw error }
            return CalendarEventDetails(
                attendees: attendeesByID[event.id] ?? [], body: "Agenda of \(event.id)", icalUID: uidByID[event.id]
            )
        }
    }

    /// Stands in for the panel: answers with `outcome` and records what the user would have seen.
    private final class FakeConfirmer: MCPMeetingConfirming {
        var outcome: MCPConfirmationOutcome
        private(set) var proposals: [MCPMeetingProposal] = []

        init(_ outcome: MCPConfirmationOutcome) { self.outcome = outcome }

        func confirm(_ proposal: MCPMeetingProposal, timeout: TimeInterval) async -> MCPConfirmationOutcome {
            proposals.append(proposal)
            return outcome
        }
    }

    private final class FakeRemovalConfirmer: MCPMeetingRemovalConfirming {
        var outcome: MCPConfirmationOutcome
        private(set) var proposals: [MCPMeetingRemovalProposal] = []

        init(_ outcome: MCPConfirmationOutcome) { self.outcome = outcome }

        private(set) var timeouts: [TimeInterval] = []

        func confirm(_ proposal: MCPMeetingRemovalProposal, timeout: TimeInterval) async -> MCPConfirmationOutcome {
            proposals.append(proposal)
            timeouts.append(timeout)
            return outcome
        }
    }

    /// Keeps its panel open until `release`, like a user who has not answered yet.
    private final class HoldingResponseConfirmer: MCPMeetingResponseConfirming {
        private(set) var proposals: [MCPMeetingResponseProposal] = []
        private var waiting: CheckedContinuation<MCPConfirmationOutcome, Never>?
        func confirm(_ proposal: MCPMeetingResponseProposal, timeout: TimeInterval) async -> MCPConfirmationOutcome {
            proposals.append(proposal)
            return await withCheckedContinuation { waiting = $0 }
        }
        func release(_ outcome: MCPConfirmationOutcome) {
            waiting?.resume(returning: outcome)
            waiting = nil
        }
    }

    private final class FakeResponseConfirmer: MCPMeetingResponseConfirming {
        var outcome: MCPConfirmationOutcome
        private(set) var proposals: [MCPMeetingResponseProposal] = []
        init(_ outcome: MCPConfirmationOutcome) { self.outcome = outcome }
        func confirm(_ proposal: MCPMeetingResponseProposal, timeout: TimeInterval) async -> MCPConfirmationOutcome {
            proposals.append(proposal)
            return outcome
        }
    }

    private let zone = TimeZone(identifier: "Europe/Moscow")!
    private let exchange = CalendarAccount(displayName: "Work", serverURL: "", email: "", accountType: .owa)
    private let local = CalendarAccount(displayName: "iCloud", serverURL: "", email: "", accountType: .eventKit)
    private let domainLogin = CalendarAccount(displayName: "", serverURL: "https://mail", email: "CORP\\me", accountType: .owa)
    private let me = ResolvedAttendee(displayName: "Баженов Илья Андреевич", email: "me@corp.ru", jobTitle: nil)
    private let namesake = ResolvedAttendee(displayName: "Баженов Илья Юрьевич", email: "ibazhenov@corp.ru", jobTitle: nil)

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0, month: Int = 10) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    private var now: Date { date(5, 12) }

    private func event(
        _ id: String,
        day: Int,
        hour: Int,
        minutes: Int = 60,
        account: CalendarAccount? = nil,
        response: MeetingResponseType = .accepted,
        cancelled: Bool = false,
        organizer: String? = nil,
        isOrganizer: Bool = false,
        attendees: [EventAttendee]? = nil,
        joinURL: URL? = nil,
        series: String? = nil,
        month: Int = 10
    ) -> CalendarEvent {
        let start = date(day, hour, month: month)
        return CalendarEvent(
            id: id, title: id, startDate: start, endDate: start.addingTimeInterval(TimeInterval(minutes * 60)),
            location: nil, bodyPreview: "preview \(id)", joinURL: joinURL, platform: joinURL == nil ? .generic : .teams,
            isAllDay: false, organizer: organizer, accountID: (account ?? exchange).id, isCancelled: cancelled, isOrganizer: isOrganizer, responseType: response,
            changeKey: "ck-\(id)", icalUID: series, seriesID: series, detailedAttendees: attendees
        )
    }

    private func makeTools(
        events: [CalendarEvent],
        provider: DetailsProvider? = nil,
        localProvider: DetailsProvider? = nil,
        enabled: Bool = true,
        confirmer: FakeConfirmer = FakeConfirmer(.rejected),
        removalConfirmer: FakeRemovalConfirmer = FakeRemovalConfirmer(.rejected),
        responseConfirmer: any MCPMeetingResponseConfirming = FakeResponseConfirmer(.rejected),
        canCreateMeetings: Bool = true,
        canRemoveMeetings: Bool = true,
        canRespondMeetings: Bool = true,
        onDemandDeadline: TimeInterval = MCPCalendarTools.onDemandDeadline,
        handOff: @escaping (MeetingDraftSeed) -> Void = { _ in },
        uptime: @escaping () -> TimeInterval = { 0 }
    ) -> (MCPCalendarTools, CalendarService) {
        let providers: [any CalendarProvider] = [provider ?? DetailsProvider(account: exchange), localProvider ?? DetailsProvider(account: local)]
        let service = CalendarService(
            providers: providers,
            notificationService: SilentNotificationService(),
            customMeetingReminders: SilentMeetingReminderController(),
            loadPersistedAccounts: false,
            startBackgroundTasks: false,
            clock: { [now] in now }
        )
        service.replaceEventsForTests(events)
        service.replaceAccountsForTests([exchange, local])
        // The real sync window: start of day -7 days ... now +30 days.
        service.setEventCoverageForTests(EventCoverage(
            start: date(5, 0).addingTimeInterval(-7 * 86400),
            end: now.addingTimeInterval(30 * 86400),
            refreshedAt: date(5, 11, 55)
        ))
        let tools = MCPCalendarTools(
            calendarService: service,
            onDemandDeadline: onDemandDeadline,
            confirmer: confirmer,
            removalConfirmer: removalConfirmer,
            responseConfirmer: responseConfirmer,
            handOff: handOff,
            clock: { [now] in now },
            timeZone: { [zone] in zone },
            uptime: uptime,
            isEnabled: { enabled },
            canCreateMeetings: { canCreateMeetings },
            canRemoveMeetings: { canRemoveMeetings },
            canRespondMeetings: { canRespondMeetings }
        )
        return (tools, service)
    }

    private func ids(_ value: JSONValue?) -> [String] {
        value?.arrayValue?.compactMap { $0["title"]?.stringValue } ?? []
    }

    // MARK: - Common

    func testDisabledServerReturnsNoData() async {
        let (tools, _) = makeTools(events: [event("a", day: 5, hour: 14)], enabled: false)
        let result = await tools.call(name: "list_events", arguments: [:])
        XCTAssertRefusal(result, .serverDisabled)
        XCTAssertTrue(result.errorMessage?.contains("Settings") == true)
    }

    func testEveryAnswerSaysHowFreshTheDataIs() async {
        let (tools, _) = makeTools(events: [])
        let status = await tools.call(name: "get_status", arguments: [:]).structured
        XCTAssertEqual(status?["now"], "2026-10-05T12:00:00+03:00")
        XCTAssertEqual(status?["timezone"], "Europe/Moscow")
        XCTAssertEqual(status?["data_as_of"], "2026-10-05T11:55:00+03:00")
        XCTAssertNotNil(status?["coverage"]?["from"])
        XCTAssertEqual(status?["sync_state"], "idle")
    }

    func testStatusNamesEveryAccountAndGivesTheUsersAddress() async {
        let (tools, service) = makeTools(events: [])
        service.replaceAccountsForTests([
            CalendarAccount(displayName: "", serverURL: "https://mail", email: "me@corp.ru", accountType: .owa),
            CalendarAccount(displayName: " ", serverURL: "https://mail", email: "CORP\\me", accountType: .owa),
            CalendarAccount(displayName: "", serverURL: "", email: "", accountType: .eventKit),
            CalendarAccount(displayName: "Work", serverURL: "https://mail", email: "me@corp.ru", accountType: .owa),
        ])

        let accounts = await tools.call(name: "get_status", arguments: [:]).structured?["accounts"]?.arrayValue ?? []

        XCTAssertEqual(accounts.map { $0["name"] }, ["me@corp.ru", "CORP\\me", "macOS Calendar", "Work"])
        XCTAssertEqual(accounts.map { $0["email"] }, ["me@corp.ru", .null, .null, "me@corp.ru"])
        // A DOMAIN\login is not an address, but still says who the user is.
        XCTAssertEqual(accounts[1]["login"], "CORP\\me")
        XCTAssertNil(accounts[0]["login"])
        XCTAssertNil(accounts[2]["login"])
    }

    func testStatusLooksUpTheAddressBehindADomainLogin() async {
        let provider = DetailsProvider(account: exchange, people: [ivanov, me, namesake], ownEmail: "me@corp.ru")
        let (tools, _) = makeTools(events: [
            event("mine", day: 6, hour: 10, response: .organizer, organizer: "Баженов Илья Андреевич"),
            event("theirs", day: 6, hour: 12, organizer: "Иванов Иван"),
        ], provider: provider)

        let accounts = await tools.call(name: "get_status", arguments: [:]).structured?["accounts"]?.arrayValue ?? []
        let work = accounts.first { $0["account_id"] == .string(exchange.id.uuidString) }

        XCTAssertEqual(work?["email"], "me@corp.ru")
        XCTAssertEqual(work?["user_name"], "Баженов Илья Андреевич")
        // Calendars without a sign-in address get no lookup and no name.
        let calendar = accounts.first { $0["account_id"] == .string(local.id.uuidString) }
        XCTAssertEqual(calendar?["email"], .null)
        XCTAssertNil(calendar?["user_name"])

        // One lookup serves get_status and find_people alike.
        let search = await tools.call(name: "find_people", arguments: ["query": "Баженов"]).structured
        let people = search?["people"]?.arrayValue ?? []
        XCTAssertEqual(people.filter { $0["is_you"] == true }.map { $0["email"] }, ["me@corp.ru"])
        XCTAssertEqual(people.count, 2)
        let lookups = await provider.ownEmailCalls
        XCTAssertEqual(lookups, 1)
    }

    func testStatusSaysWhoTheUserIsEvenWhenTheLookupFails() async {
        let provider = DetailsProvider(account: domainLogin, ownEmailError: URLError(.timedOut))
        let (tools, service) = makeTools(events: [], provider: provider)
        service.replaceAccountsForTests([domainLogin])

        let account = await tools.call(name: "get_status", arguments: [:]).structured?["accounts"]?.arrayValue?.first

        XCTAssertEqual(account?["email"], .null)
        XCTAssertEqual(account?["login"], "CORP\\me")
    }

    func testAddressFoundForADomainLoginKeepsTheLoginToo() async {
        let provider = DetailsProvider(account: domainLogin, ownEmail: "me@corp.ru")
        let (tools, service) = makeTools(events: [], provider: provider)
        service.replaceAccountsForTests([domainLogin])

        let account = await tools.call(name: "get_status", arguments: [:]).structured?["accounts"]?.arrayValue?.first

        XCTAssertEqual(account?["email"], "me@corp.ru")
        XCTAssertEqual(account?["login"], "CORP\\me")
    }

    func testEventDetailsMarkTheUserAmongAttendees() async {
        let attendees = [
            EventAttendee(name: "Иванов Иван", email: "ivanov@corp.ru", kind: .required, response: .accepted),
            EventAttendee(name: "Баженов Илья Андреевич", email: "ME@corp.ru", kind: .required, response: .accepted),
        ]
        let provider = DetailsProvider(account: exchange, attendeesByID: ["a": attendees], ownEmail: "me@corp.ru")
        let (tools, _) = makeTools(events: [event("a", day: 6, hour: 10)], provider: provider)
        _ = await tools.call(name: "get_status", arguments: [:])

        let details = await tools.call(name: "get_event_details", arguments: ["event_id": .string(MCPEventID.short("a"))]).structured

        let marked = details?["attendees"]?.arrayValue?.map { $0["is_you"] }
        XCTAssertEqual(marked, [nil, true])
    }

    // MARK: - list_events

    func testListEventsDefaultsToTodayAndHidesDeclined() async {
        let (tools, _) = makeTools(events: [
            event("today", day: 5, hour: 14),
            event("declined", day: 5, hour: 15, response: .declined),
            event("tomorrow", day: 6, hour: 10),
        ])
        let result = await tools.call(name: "list_events", arguments: [:]).structured
        XCTAssertEqual(ids(result?["events"]), ["today"])
        XCTAssertEqual(result?["truncated"], false)
        let first = result?["events"]?.arrayValue?.first
        XCTAssertEqual(first?["event_id"]?.stringValue?.count, 12)
        XCTAssertNil(first?["join_url"], "join links only come from get_event_details")
    }

    func testListEventsFiltersAndLimits() async {
        let (tools, _) = makeTools(events: [
            event("Sprint review", day: 6, hour: 10),
            event("Retro", day: 6, hour: 11, response: .declined),
            event("Planning", day: 7, hour: 10),
        ])
        let declined = await tools.call(name: "list_events", arguments: ["from": "2026-10-06", "to": "2026-10-07", "response": ["declined"]]).structured
        XCTAssertEqual(ids(declined?["events"]), ["Retro"])

        let query = await tools.call(name: "list_events", arguments: ["from": "2026-10-06", "to": "2026-10-07", "query": "sprint"]).structured
        XCTAssertEqual(ids(query?["events"]), ["Sprint review"])

        let limited = await tools.call(name: "list_events", arguments: ["from": "2026-10-06", "to": "2026-10-07", "limit": 1]).structured
        XCTAssertEqual(limited?["truncated"], true)
        XCTAssertEqual(limited?["total"], 2)
    }

    func testListEventsLoadsPeriodsOutsideTheSyncWindow() async {
        let provider = DetailsProvider(account: exchange, archive: [event("august", day: 10, hour: 11, month: 8)])
        let (tools, _) = makeTools(events: [event("a", day: 5, hour: 14)], provider: provider)

        let wide = await tools.call(name: "list_events", arguments: ["from": "2026-08-01", "to": "2026-10-06"]).structured
        XCTAssertEqual(wide?["range"]?["clipped"], false)
        XCTAssertEqual(wide?["range"]?["outside_sync_window"], true)
        XCTAssertEqual(ids(wide?["events"]), ["august", "a"])

        // Blocks already loaded are not asked for again.
        let calls = await provider.fetchCalls.count
        XCTAssertGreaterThan(calls, 0)
        let again = await tools.call(name: "list_events", arguments: ["from": "2026-08-05", "to": "2026-08-20"]).structured
        XCTAssertEqual(ids(again?["events"]), ["august"])
        let callsAfter = await provider.fetchCalls.count
        XCTAssertEqual(callsAfter, calls)

        // The archived meeting can be opened like any other.
        let handle = wide?["events"]?.arrayValue?.first?["event_id"]?.stringValue ?? ""
        let details = await tools.call(name: "get_event_details", arguments: ["event_id": .string(handle)])
        XCTAssertFalse(details.isError)
        XCTAssertEqual(details.structured?["title"], "august")
    }

    func testInsideCoverageTheSyncedCopyWins() async {
        // The block still holds a meeting the sync no longer has (moved or cancelled since).
        let provider = DetailsProvider(account: exchange, archive: [
            event("stale", day: 1, hour: 10),
            event("august", day: 20, hour: 10, month: 9),
        ])
        let (tools, _) = makeTools(events: [event("a", day: 5, hour: 14)], provider: provider)
        let result = await tools.call(name: "list_events", arguments: ["from": "2026-09-15", "to": "2026-10-06"]).structured
        XCTAssertEqual(ids(result?["events"]), ["august", "a"])
    }

    func testOnDemandPeriodsAreLimited() async {
        let provider = DetailsProvider(account: exchange)
        let (tools, _) = makeTools(events: [], provider: provider)

        let tooOld = await tools.call(name: "list_events", arguments: ["from": "2025-01-01", "to": "2025-02-01"])
        XCTAssertRefusal(tooOld, .invalidArgument)
        XCTAssertTrue(tooOld.errorMessage?.contains("a year back") == true)

        // Ten months back: only the 184 days nearest to the sync window are loaded.
        let long = await tools.call(name: "list_events", arguments: ["from": "2026-01-01", "to": "2026-10-06"]).structured
        XCTAssertEqual(long?["range"]?["clipped"], true)
        XCTAssertNotNil(long?["range"]?["note"]?.stringValue)
        let coverageStart = date(5, 0).addingTimeInterval(-7 * 86400)
        let expectedFrom = MCPDateCoder(timeZone: zone).string(coverageStart.addingTimeInterval(-MCPCalendarArchive.maxSpan))
        XCTAssertEqual(long?["range"]?["from"]?.stringValue, expectedFrom)
        let calls = await provider.fetchCalls.count
        XCTAssertLessThanOrEqual(calls, 7)
    }

    func testAnAccountThatFailsIsReportedAndOthersStillAnswer() async {
        let provider = DetailsProvider(account: exchange, fetchError: URLError(.timedOut))
        let localProvider = DetailsProvider(account: local, archive: [event("dentist", day: 12, hour: 9, account: local, month: 8)])
        let (tools, _) = makeTools(events: [], provider: provider, localProvider: localProvider)

        let result = await tools.call(name: "list_events", arguments: ["from": "2026-08-01", "to": "2026-08-31"]).structured
        XCTAssertEqual(ids(result?["events"]), ["dentist"])
        XCTAssertEqual(result?["unavailable_accounts"]?.arrayValue?.first?["account_id"]?.stringValue, exchange.id.uuidString)
        XCTAssertNotNil(result?["unavailable_note"])
        // After the first failure the account's other blocks are not asked for.
        let calls = await provider.fetchCalls.count
        XCTAssertLessThanOrEqual(calls, MCPAccessGuard.maxConcurrentRequests)

        // A local calendar is read every time: it is always current.
        _ = await tools.call(name: "list_events", arguments: ["from": "2026-08-01", "to": "2026-08-31"])
        let localCalls = await localProvider.fetchCalls.count
        XCTAssertEqual(localCalls, 2)
    }

    func testSlowCalendarIsAnsweredAtTheDeadlineAndArchivedForTheNextCall() async throws {
        let provider = DetailsProvider(
            account: exchange, archive: [event("august", day: 10, hour: 11, month: 8)], fetchDelay: .milliseconds(300)
        )
        let (tools, _) = makeTools(events: [], provider: provider, onDemandDeadline: 0.05)
        let arguments: [String: JSONValue] = ["from": "2026-07-01", "to": "2026-08-31", "account_id": .string(exchange.id.uuidString)]

        let first = await tools.call(name: "list_events", arguments: arguments).structured
        XCTAssertEqual(ids(first?["events"]), [])
        XCTAssertTrue(first?["unavailable_accounts"]?.arrayValue?.first?["reason"]?.stringValue?.contains("did not answer") == true)

        // The two requests already sent finish and are kept; those still queued are never sent.
        try await Task.sleep(for: .milliseconds(800))
        let calls = await provider.fetchCalls.count
        XCTAssertEqual(calls, MCPAccessGuard.maxConcurrentRequests)

        // 5–15 August lies in a block that was loaded (blocks start on 20 July and 20 August).
        let second = await tools.call(name: "list_events", arguments: ["from": "2026-08-05", "to": "2026-08-15"]).structured
        XCTAssertEqual(ids(second?["events"]), ["august"])
        let callsAfter = await provider.fetchCalls.count
        XCTAssertEqual(callsAfter, calls)
    }

    func testArchiveCapacityIsPerAccount() {
        let archive = MCPCalendarArchive()
        let other = UUID()
        for block in 0..<MCPCalendarArchive.capacity {
            archive.store([], for: .init(accountID: exchange.id, block: block), now: now)
        }
        archive.store([], for: .init(accountID: other, block: 0), now: now)
        XCTAssertNotNil(archive.events(for: .init(accountID: exchange.id, block: 0), now: now))
        XCTAssertEqual(archive.count, MCPCalendarArchive.capacity + 1)

        archive.store([], for: .init(accountID: exchange.id, block: 100), now: now)
        XCTAssertNil(archive.events(for: .init(accountID: exchange.id, block: 0), now: now))
        XCTAssertNotNil(archive.events(for: .init(accountID: other, block: 0), now: now))
    }

    func testExpiredAccountBlocksLoadAgainButKeepTheirEventIDs() {
        let archive = MCPCalendarArchive()
        let other = UUID()
        let held = event("august", day: 10, hour: 11, month: 8)
        archive.store([held], for: .init(accountID: exchange.id, block: 0), now: now)
        archive.store([], for: .init(accountID: other, block: 0), now: now)

        archive.expire(accountID: exchange.id)
        XCTAssertNil(archive.events(for: .init(accountID: exchange.id, block: 0), now: now), "loaded again on the next question")
        XCTAssertNotNil(archive.events(for: .init(accountID: other, block: 0), now: now), "other accounts are untouched")
        XCTAssertEqual(archive.allEvents.map(\.id), [held.id], "an event_id handed out still resolves")
    }

    func testOnDemandLoadsStopWhileSyncIsBlocked() async {
        let provider = DetailsProvider(account: exchange, archive: [event("august", day: 10, hour: 11, month: 8)])
        let (tools, service) = makeTools(events: [], provider: provider)
        service.debugForceAuthBlock()

        let result = await tools.call(name: "list_events", arguments: ["from": "2026-08-01", "to": "2026-08-31"])
        XCTAssertRefusal(result, .authFailed)
        let calls = await provider.fetchCalls.count
        XCTAssertEqual(calls, 0)
    }

    func testPersonSearchReachesBeyondTheSyncWindow() async {
        let provider = DetailsProvider(account: exchange, archive: [event("1:1", day: 14, hour: 15, organizer: "Иванов Пётр", month: 7)])
        let (tools, _) = makeTools(events: [], provider: provider)

        let byDefault = await tools.call(name: "find_events_with_person", arguments: ["person": "Пётр Иванов", "direction": "past"]).structured
        XCTAssertEqual(ids(byDefault?["past"]), [])

        let further = await tools.call(name: "find_events_with_person", arguments: [
            "person": "Пётр Иванов", "direction": "past", "from": "2026-06-01",
        ]).structured
        XCTAssertEqual(ids(further?["past"]), ["1:1"])
    }

    func testScheduleStatsForAPastMonth() async {
        let provider = DetailsProvider(account: exchange, archive: [
            event("x", day: 3, hour: 10, month: 8), event("y", day: 4, hour: 10, minutes: 30, month: 8),
        ])
        let (tools, _) = makeTools(events: [], provider: provider)
        let result = await tools.call(name: "get_schedule_stats", arguments: ["from": "2026-08-03", "to": "2026-08-09"]).structured
        XCTAssertEqual(result?["totals"]?["meeting_count"], 2)
        XCTAssertEqual(result?["totals"]?["meeting_minutes"], 90)
    }

    func testOnlyToMeansThePeriodEndingThere() async {
        let (tools, _) = makeTools(events: [event("sat", day: 3, hour: 10), event("fri", day: 2, hour: 10)])
        let day = await tools.call(name: "list_events", arguments: ["to": "2026-10-03"]).structured
        XCTAssertEqual(day?["range"]?["from"], "2026-10-03T00:00:00+03:00")
        XCTAssertEqual(ids(day?["events"]), ["sat"])

        let week = await tools.call(name: "get_schedule_stats", arguments: ["to": "2026-10-04"]).structured
        XCTAssertEqual(week?["range"]?["from"], "2026-09-28T00:00:00+03:00")
        XCTAssertEqual(week?["range"]?["to"], "2026-10-05T00:00:00+03:00")
    }

    func testInvalidArgumentsAreToolErrors() async {
        let (tools, _) = makeTools(events: [])
        let badDate = await tools.call(name: "list_events", arguments: ["from": "tomorrow"])
        XCTAssertRefusal(badDate, .invalidArgument)
        let badLimit = await tools.call(name: "list_events", arguments: ["limit": 1000])
        XCTAssertRefusal(badLimit, .invalidArgument)
    }

    // MARK: - get_current_and_next

    func testCurrentAndNextIgnoresDeclined() async {
        let (tools, _) = makeTools(events: [
            event("running", day: 5, hour: 11, minutes: 90),
            event("declined-next", day: 5, hour: 13, response: .declined),
            event("next", day: 5, hour: 14),
        ])
        let result = await tools.call(name: "get_current_and_next", arguments: [:]).structured
        XCTAssertEqual(ids(result?["current"]), ["running"])
        XCTAssertEqual(ids(result?["next"]), ["next"])
        XCTAssertEqual(result?["free_until"], .null)
        XCTAssertEqual(result?["minutes_until_next"], 120)
    }

    // MARK: - get_schedule_stats

    func testScheduleStatsDefaultsToCurrentWeek() async {
        let (tools, _) = makeTools(events: [
            event("mon", day: 5, hour: 10),
            event("tue", day: 6, hour: 10),
            event("next-week", day: 12, hour: 10),
        ])
        let result = await tools.call(name: "get_schedule_stats", arguments: [:]).structured
        XCTAssertEqual(result?["range"]?["from"], "2026-10-05T00:00:00+03:00")
        XCTAssertEqual(result?["range"]?["to"], "2026-10-12T00:00:00+03:00")
        XCTAssertEqual(result?["totals"]?["meeting_count"], 2)
        XCTAssertEqual(result?["totals"]?["meeting_minutes"], 120)
        XCTAssertEqual(result?["days"]?.arrayValue?.count, 7)
    }

    func testScheduleStatsValidatesWorkingHours() async {
        let (tools, _) = makeTools(events: [])
        let result = await tools.call(name: "get_schedule_stats", arguments: ["work_start": "18:00", "work_end": "09:00"])
        XCTAssertRefusal(result, .invalidArgument)
    }

    // MARK: - find_events_with_person

    func testFindsNearestPastMeetingWithFewRequests() async {
        let ivanov = EventAttendee(name: "Иванов Иван", email: "ivanov@corp.ru", kind: .required, response: .accepted)
        let provider = DetailsProvider(account: exchange, attendeesByID: ["mon-9": [ivanov], "fri": [ivanov]])
        let (tools, _) = makeTools(events: [
            event("fri", day: 2, hour: 10),
            event("mon-9", day: 5, hour: 9),
            event("mon-10", day: 5, hour: 10),
            event("mon-11", day: 5, hour: 11),
        ], provider: provider)

        let result = await tools.call(name: "find_events_with_person", arguments: ["person": "Иван Иванов", "direction": "past", "limit": 1]).structured
        XCTAssertEqual(ids(result?["past"]), ["mon-9"])
        XCTAssertEqual(result?["past"]?.arrayValue?.first?["match"], "required")
        XCTAssertEqual(result?["partial"], false)
        // Nearest first, stopping at the first hit: mon-11, mon-10, mon-9 — never fri.
        let calls = await provider.detailCalls
        XCTAssertEqual(calls, ["mon-11", "mon-10", "mon-9"])
    }

    func testOrganizerAndLocalAttendeesNeedNoRequests() async {
        let provider = DetailsProvider(account: exchange)
        let petrov = EventAttendee(name: "Petrov Petr", email: "petrov@corp.ru", kind: .optional, response: .tentative)
        let (tools, _) = makeTools(events: [
            event("organized", day: 6, hour: 10, organizer: "Петров Пётр"),
            event("icloud", day: 7, hour: 10, account: local, attendees: [petrov]),
        ], provider: provider)

        let result = await tools.call(name: "find_events_with_person", arguments: ["person": "Петров", "direction": "upcoming"]).structured
        XCTAssertEqual(ids(result?["upcoming"]), ["organized", "icloud"])
        XCTAssertEqual(result?["upcoming"]?.arrayValue?.map { $0["match"] }, ["organizer", "optional"])
        let calls = await provider.detailCalls
        XCTAssertTrue(calls.isEmpty)
    }

    func testPersonSearchSkipsDeclinedAndCancelledUnlessAsked() async {
        let provider = DetailsProvider(account: exchange)
        let (tools, _) = makeTools(events: [
            event("met", day: 2, hour: 10, organizer: "Петров Пётр"),
            event("declined", day: 5, hour: 9, response: .declined, organizer: "Петров Пётр"),
            event("cancelled", day: 5, hour: 10, cancelled: true, organizer: "Петров Пётр"),
        ], provider: provider)

        let byDefault = await tools.call(name: "find_events_with_person", arguments: ["person": "Петров", "direction": "past"]).structured
        // The last time they actually met, not the meeting the user declined.
        XCTAssertEqual(ids(byDefault?["past"]), ["met"])

        let all = await tools.call(
            name: "find_events_with_person",
            arguments: ["person": "Петров", "direction": "past", "include_declined_and_cancelled": true]
        ).structured
        XCTAssertEqual(ids(all?["past"]), ["cancelled", "declined", "met"])
        let calls = await provider.detailCalls
        XCTAssertTrue(calls.isEmpty)
    }

    func testRequestBudgetMakesTheAnswerPartialAndASecondCallContinues() async {
        let provider = DetailsProvider(account: exchange)
        var events: [CalendarEvent] = []
        for index in 0..<45 {
            events.append(event("m\(index)", day: 6 + index / 8, hour: 9 + index % 8))
        }
        let (tools, _) = makeTools(events: events, provider: provider)

        let first = await tools.call(name: "find_events_with_person", arguments: ["person": "nobody@corp.ru", "direction": "upcoming"]).structured
        XCTAssertEqual(first?["partial"], true)
        XCTAssertEqual(first?["unchecked_count"], 5)
        XCTAssertEqual(first?["detail_requests_made"], 40)

        let second = await tools.call(name: "find_events_with_person", arguments: ["person": "nobody@corp.ru", "direction": "upcoming"]).structured
        XCTAssertEqual(second?["partial"], false)
        XCTAssertEqual(second?["detail_requests_made"], 5)
        let calls = await provider.detailCalls
        XCTAssertEqual(calls.count, 45)
    }

    func testAmbiguousNamesAreReported() async {
        let a = EventAttendee(name: "Иванов Иван", email: "ivan@corp.ru", kind: .required, response: .accepted)
        let b = EventAttendee(name: "Иванов Пётр", email: "petr.ivanov@corp.ru", kind: .required, response: .accepted)
        let (tools, _) = makeTools(events: [
            event("one", day: 6, hour: 10, account: local, attendees: [a]),
            event("two", day: 6, hour: 11, account: local, attendees: [b]),
        ])
        let result = await tools.call(name: "find_events_with_person", arguments: ["person": "Иванов"]).structured
        XCTAssertEqual(result?["ambiguous_people"]?.arrayValue?.count, 2)
    }

    func testBlockedSyncMakesNoRequests() async {
        let provider = DetailsProvider(account: exchange)
        let (tools, service) = makeTools(events: [event("a", day: 6, hour: 10)], provider: provider)
        service.debugForceAuthBlock()

        let result = await tools.call(name: "find_events_with_person", arguments: ["person": "Иванов"]).structured
        XCTAssertEqual(result?["partial"], true)
        XCTAssertNotNil(result?["blocked_reason"])
        let calls = await provider.detailCalls
        XCTAssertTrue(calls.isEmpty)
    }

    func testAuthFailureLatchesTheCircuitBreaker() async {
        let provider = DetailsProvider(account: exchange, error: OWAError.authenticationFailed("rejected"))
        let (tools, service) = makeTools(events: [event("a", day: 6, hour: 10), event("b", day: 6, hour: 11)], provider: provider)

        let result = await tools.call(name: "find_events_with_person", arguments: ["person": "Иванов", "direction": "upcoming"]).structured

        XCTAssertTrue(service.syncStatus.isAuthenticationRequired)
        XCTAssertNotNil(result?["blocked_reason"])
        // The first rejection stops the walk: no second credential submission.
        let calls = await provider.detailCalls
        XCTAssertEqual(calls, ["a"])
    }

    // MARK: - Series and iCalendar UID

    func testSeriesIDListsEveryOccurrenceTheCalendarHolds() async {
        let (tools, _) = makeTools(events: [
            event("weekly-past", day: 1, hour: 15, series: "S1"),
            event("weekly-now", day: 5, hour: 15, series: "S1"),
            event("weekly-next", day: 12, hour: 15, series: "S1"),
            event("other-series", day: 5, hour: 10, series: "S2"),
            event("one-off", day: 5, hour: 11),
        ])

        let today = await tools.call(name: "list_events", arguments: [:]).structured
        let fields = today?["events"]?.arrayValue?.first { $0["title"] == "weekly-now" }
        XCTAssertEqual(fields?["series_id"], "S1")
        XCTAssertEqual(fields?["ical_uid"], "S1")
        XCTAssertEqual(fields?["is_recurring"], true)
        let oneOff = today?["events"]?.arrayValue?.first { $0["title"] == "one-off" }
        XCTAssertNil(oneOff?["series_id"])
        XCTAssertNil(oneOff?["is_recurring"])

        // Without from/to the whole coverage, not just today.
        let series = await tools.call(name: "list_events", arguments: ["series_id": "S1"]).structured
        XCTAssertEqual(ids(series?["events"]), ["weekly-past", "weekly-now", "weekly-next"])
        let empty = await tools.call(name: "list_events", arguments: ["series_id": " "])
        XCTAssertRefusal(empty, .invalidArgument)
    }

    func testOneOffMeetingUIDAppearsOnceItsDetailsLoad() async {
        let provider = DetailsProvider(account: exchange, uidByID: ["a": "UID-A"])
        let (tools, _) = makeTools(events: [event("a", day: 5, hour: 14)], provider: provider)
        let handle = MCPEventID.short("a")

        let before = await tools.call(name: "list_events", arguments: [:]).structured?["events"]?.arrayValue?.first
        XCTAssertNil(before?["ical_uid"])

        let details = await tools.call(name: "get_event_details", arguments: ["event_id": .string(handle)]).structured
        XCTAssertEqual(details?["ical_uid"], "UID-A")
        let after = await tools.call(name: "list_events", arguments: [:]).structured?["events"]?.arrayValue?.first
        XCTAssertEqual(after?["ical_uid"], "UID-A")
    }

    // MARK: - match_event

    func testParticipantsPickTheRightOneOfParallelMeetings() async {
        // Three meetings at 16:00, a recording from 16:28 for 93 minutes with known speakers.
        let provider = DetailsProvider(account: exchange, attendeesByID: [
            "ISCA": [EventAttendee(name: "Петров Пётр", email: "petrov@corp.ru", kind: .required, response: .accepted)],
            "Back Leads": [
                EventAttendee(name: "Аниканов Алексей", email: "anikanov@corp.ru", kind: .required, response: .accepted),
                EventAttendee(name: "Федосеев Вадим", email: "fedoseev@corp.ru", kind: .required, response: .accepted),
            ],
            "English": [],
        ])
        let (tools, _) = makeTools(events: [
            event("ISCA", day: 5, hour: 16, minutes: 30),
            event("English", day: 5, hour: 16),
            event("Back Leads", day: 5, hour: 16, minutes: 90),
        ], provider: provider)

        let result = await tools.call(name: "match_event", arguments: [
            "start": "2026-10-05T16:28", "duration_minutes": 93,
            "participants": ["Алексей Аниканов", "Федосеев Вадим"],
        ]).structured

        let best = result?["candidates"]?.arrayValue?.first
        XCTAssertEqual(best?["title"], "Back Leads")
        XCTAssertEqual(best?["matched_participants"], ["Алексей Аниканов", "Федосеев Вадим"])
        XCTAssertEqual(result?["ambiguous"], false)
        XCTAssertNotEqual(result?["confidence"], "low")
    }

    func testIdenticalParallelMeetingsAreAmbiguousWithoutMoreToGoOn() async {
        let (tools, _) = makeTools(events: [
            event("A", day: 5, hour: 16),
            event("B", day: 5, hour: 16),
        ])

        let result = await tools.call(name: "match_event", arguments: ["start": "2026-10-05T16:00", "end": "2026-10-05T17:00"]).structured

        XCTAssertEqual(result?["ambiguous"], true)
        XCTAssertEqual(result?["candidates"]?.arrayValue?.count, 2)
    }

    func testNothingIsMatchedOutsideTheCalendarData() async {
        let (tools, _) = makeTools(events: [event("old", day: 5, hour: 10)])

        let result = await tools.call(name: "match_event", arguments: ["start": "2025-08-01T10:00"])
        XCTAssertRefusal(result, .invalidArgument)
        XCTAssertTrue(result.errorMessage?.contains("outside") == true)

        let empty = await tools.call(name: "match_event", arguments: ["start": "2026-10-05T03:00"]).structured
        XCTAssertEqual(empty?["confidence"], "none")
        XCTAssertEqual(empty?["candidates"]?.arrayValue?.count, 0)
    }

    func testOldRecordingsAreMatchedFromLoadedMeetings() async {
        let provider = DetailsProvider(account: exchange, archive: [event("Demo", day: 1, hour: 10, month: 8)])
        let (tools, _) = makeTools(events: [], provider: provider)
        let result = await tools.call(name: "match_event", arguments: ["start": "2026-08-01T10:05", "duration_minutes": 50]).structured
        XCTAssertEqual(ids(result?["candidates"]), ["Demo"])
        XCTAssertEqual(result?["confidence"], "high")
    }

    func testNoMatchIsGuessedWhenTheCalendarCannotBeReadThere() async {
        let provider = DetailsProvider(account: exchange, fetchError: URLError(.notConnectedToInternet))
        let (tools, _) = makeTools(events: [], provider: provider)
        let result = await tools.call(name: "match_event", arguments: [
            "start": "2026-08-01T10:05", "account_id": .string(exchange.id.uuidString),
        ])
        XCTAssertRefusal(result, .exchangeError)
        XCTAssertTrue(result.errorMessage?.contains("do not guess") == true)
    }

    func testAttendeeListsAreLoadedForAFewLikelyMeetingsOnly() async {
        let provider = DetailsProvider(account: exchange)
        let events = (0..<8).map { event("m\($0)", day: 5, hour: 14) }
        let (tools, _) = makeTools(events: events, provider: provider)

        let result = await tools.call(name: "match_event", arguments: [
            "start": "2026-10-05T14:00", "participants": ["Иванов"], "limit": 10,
        ]).structured

        let calls = await provider.detailCalls
        XCTAssertEqual(calls.count, MCPCalendarTools.matchAttendeeLoads)
        let unknown = result?["candidates"]?.arrayValue?.filter { $0["attendees_unknown"] == true }.count
        XCTAssertEqual(unknown, 8 - MCPCalendarTools.matchAttendeeLoads)
    }

    func testMatchEventRejectsConflictingArguments() async {
        let (tools, _) = makeTools(events: [])
        let broken: [[String: JSONValue]] = [
            [:],
            ["start": "2026-10-05"],
            ["start": "2026-10-05T10:00", "end": "2026-10-05T11:00", "duration_minutes": 60],
            ["start": "2026-10-05T10:00", "end": "2026-10-05T09:00"],
            ["start": "2026-10-05T10:00", "participants": "Иванов"],
        ]
        for arguments in broken {
            let result = await tools.call(name: "match_event", arguments: arguments)
            XCTAssertRefusal(result, .invalidArgument, "\(arguments)")
        }
    }

    // MARK: - get_event_details

    func testEventDetailsLoadOnceThenComeFromCache() async throws {
        let attendee = EventAttendee(name: "Иванов Иван", email: "ivanov@corp.ru", kind: .required, response: .tentative)
        let provider = DetailsProvider(account: exchange, attendeesByID: ["a": [attendee]])
        let meeting = event("a", day: 6, hour: 10, joinURL: URL(string: "https://teams.microsoft.com/l/meetup-join/x"))
        let (tools, service) = makeTools(events: [meeting], provider: provider)
        let handle = MCPEventID.short("a")

        let first = await tools.call(name: "get_event_details", arguments: ["event_id": .string(handle)]).structured
        XCTAssertEqual(first?["details_source"], "network")
        XCTAssertEqual(first?["attendees"]?.arrayValue?.first?["response"], "tentative")
        XCTAssertEqual(first?["body"], "Agenda of a")
        XCTAssertEqual(first?["join_url"], "https://teams.microsoft.com/l/meetup-join/x")

        // A sync replaces the event and drops its details; the MCP cache still has them.
        service.replaceEventsForTests([meeting])
        let second = await tools.call(name: "get_event_details", arguments: ["event_id": .string(handle)]).structured
        XCTAssertEqual(second?["details_source"], "cache")
        let calls = await provider.detailCalls
        XCTAssertEqual(calls.count, 1)
    }

    func testUnknownEventID() async {
        let (tools, _) = makeTools(events: [])
        let result = await tools.call(name: "get_event_details", arguments: ["event_id": "0123456789ab"])
        XCTAssertRefusal(result, .notFound)
    }

    // MARK: - find_people

    private let ivanov = ResolvedAttendee(displayName: "Иванов Иван", email: "ivanov@corp.ru", jobTitle: "Разработчик", office: "Г-502")
    private let partner = ResolvedAttendee(displayName: "Partner Ivanov", email: "ivanov@partner.com", jobTitle: nil)

    func testFindPeopleMarksAddressesOutsideTheUsersDomain() async {
        let provider = DetailsProvider(account: exchange, people: [ivanov, partner], ownEmail: "me@corp.ru")
        let (tools, _) = makeTools(events: [], provider: provider)

        let result = await tools.call(name: "find_people", arguments: ["query": "Ivanov"]).structured
        let people = result?["people"]?.arrayValue ?? []

        XCTAssertEqual(people.map { $0["email"] }, ["ivanov@corp.ru", "ivanov@partner.com"])
        XCTAssertEqual(people.map { $0["external"] }, [false, true])
        XCTAssertEqual(people.first?["job_title"], "Разработчик")
        XCTAssertEqual(people.first?["office"], "Г-502")
        XCTAssertNil(people.last?["office"])
    }

    func testFindPeopleNeedsAQueryAndAnExchangeAccount() async {
        let (tools, _) = makeTools(events: [])
        let short = await tools.call(name: "find_people", arguments: ["query": "I"])
        XCTAssertRefusal(short, .invalidArgument)
        let local = await tools.call(name: "find_people", arguments: ["query": "Ivanov", "account_id": .string(local.id.uuidString)])
        XCTAssertRefusal(local, .notSupported)
    }


    // MARK: - get_my_org

    private func orgPerson(_ name: String, _ email: String, _ title: String? = "Инженер") -> OrgPerson {
        OrgPerson(name: name, email: email, title: title)
    }

    private var myOrg: OrgHierarchy {
        OrgHierarchy(
            manager: orgPerson("Чернов М.", "boss@corp.ru", "Руководитель направления"),
            managementChain: [orgPerson("Первый П.", "ceo@corp.ru", "Председатель"), orgPerson("Второй В.", "vp@corp.ru", "Директор")],
            peers: [orgPerson("Баженов И.", "me@corp.ru", "Архитектор"), orgPerson("Петров П.", "petrov@corp.ru")],
            directReports: [orgPerson("Сидоров С.", "sidorov@corp.ru"), orgPerson("Bot_AI", "bot_ai@corp.ru", nil)]
        )
    }

    func testMyOrgDefaultsToTheUserAndLeavesThemOutOfPeers() async throws {
        let provider = DetailsProvider(account: exchange, ownEmail: "me@corp.ru", org: ["me@corp.ru": myOrg])
        let (tools, _) = makeTools(events: [], provider: provider)

        let resultCall = await tools.call(name: "get_my_org", arguments: [:]).structured
        let result = try XCTUnwrap(resultCall)

        XCTAssertEqual(result["in_directory"], true)
        XCTAssertEqual(result["person"]?["email"], "me@corp.ru")
        XCTAssertEqual(result["person"]?["title"], "Архитектор")
        XCTAssertEqual(result["person"]?["is_you"], true)
        XCTAssertEqual(result["manager"]?["email"], "boss@corp.ru")
        XCTAssertEqual(result["management_chain"]?.arrayValue?.map { $0["email"] }, ["ceo@corp.ru", "vp@corp.ru"])
        XCTAssertEqual(result["peers"]?.arrayValue?.map { $0["email"] }, ["petrov@corp.ru"])
        let reports = result["direct_reports"]?.arrayValue ?? []
        XCTAssertEqual(reports.map { $0["email"] }, ["sidorov@corp.ru", "bot_ai@corp.ru"])
        XCTAssertNil(reports[0]["likely_service_mailbox"])
        XCTAssertEqual(reports[1]["likely_service_mailbox"], true)
        XCTAssertNil(reports[1]["title"])
        XCTAssertNil(result["skip_level"])
        let calls = await provider.orgCalls
        XCTAssertEqual(calls, ["me@corp.ru"])
    }

    func testMyOrgIsRememberedAndAnOutsideAddressIsNotInTheDirectory() async throws {
        let provider = DetailsProvider(account: exchange, ownEmail: "me@corp.ru", org: ["me@corp.ru": myOrg])
        let (tools, _) = makeTools(events: [], provider: provider)

        _ = await tools.call(name: "get_my_org", arguments: [:])
        let again = await tools.call(name: "get_my_org", arguments: ["email": "ME@corp.ru"]).structured
        XCTAssertEqual(again?["manager"]?["email"], "boss@corp.ru")

        let outsideCall = await tools.call(name: "get_my_org", arguments: ["email": "someone@gmail.com"]).structured
        let outside = try XCTUnwrap(outsideCall)
        XCTAssertEqual(outside["in_directory"], false)
        XCTAssertEqual(outside["manager"], .null)
        XCTAssertEqual(outside["direct_reports"]?.arrayValue?.count, 0)
        _ = await tools.call(name: "get_my_org", arguments: ["email": "someone@gmail.com"])

        let calls = await provider.orgCalls
        XCTAssertEqual(calls, ["me@corp.ru", "someone@gmail.com"])
    }

    func testMyOrgSkipLevelLoadsEachDirectReportOnce() async throws {
        let sidorovs = OrgHierarchy(
            manager: orgPerson("Баженов И.", "me@corp.ru", "Архитектор"), managementChain: [],
            peers: [], directReports: [orgPerson("Младший М.", "junior@corp.ru", "Разработчик")]
        )
        let provider = DetailsProvider(
            account: exchange, ownEmail: "me@corp.ru",
            org: ["me@corp.ru": myOrg, "sidorov@corp.ru": sidorovs], failingOrg: ["bot_ai@corp.ru"]
        )
        let (tools, _) = makeTools(events: [], provider: provider)

        let resultCall = await tools.call(name: "get_my_org", arguments: ["include_skip_level": true]).structured
        let result = try XCTUnwrap(resultCall)

        let reports = result["direct_reports"]?.arrayValue ?? []
        XCTAssertEqual(reports.first?["direct_reports"]?.arrayValue?.map { $0["email"] }, ["junior@corp.ru"])
        XCTAssertNil(reports.last?["direct_reports"])
        XCTAssertEqual(result["skip_level"]?["requested"], 2)
        XCTAssertEqual(result["skip_level"]?["loaded"], 1)
        XCTAssertNotNil(result["skip_level"]?["error"])
        let calls = await provider.orgCalls
        XCTAssertEqual(calls, ["me@corp.ru", "sidorov@corp.ru", "bot_ai@corp.ru"])
    }

    func testMyOrgRejectsANonAddressAndReportsAFailedRequest() async {
        let provider = DetailsProvider(account: exchange, ownEmail: "me@corp.ru", failingOrg: ["me@corp.ru"])
        let (tools, _) = makeTools(events: [], provider: provider)

        let bad = await tools.call(name: "get_my_org", arguments: ["email": "Иванов"])
        XCTAssertRefusal(bad, .invalidArgument)
        let failed = await tools.call(name: "get_my_org", arguments: [:])
        XCTAssertRefusal(failed, .exchangeError)
    }


    // MARK: - get_person_profile

    private func profile(_ email: String, title: String? = "Архитектор", manager: OrgPerson? = nil) -> PersonProfile {
        PersonProfile(
            name: "Иванов И.", email: email, isDistributionList: false, title: title, department: "Дирекция",
            office: "Г-502", city: "Москва", company: nil, manager: manager, directReportsCount: 1
        )
    }

    func testPersonProfileGivesDepartmentOfficeAndManagerAndIsRemembered() async throws {
        let boss = OrgPerson(name: "Петров П.", email: "boss@corp.ru", title: nil)
        let provider = DetailsProvider(account: exchange, ownEmail: "me@corp.ru", profiles: ["me@corp.ru": profile("me@corp.ru", manager: boss)])
        let (tools, _) = makeTools(events: [], provider: provider)

        let firstCall = await tools.call(name: "get_person_profile", arguments: ["emails": ["me@corp.ru", "nobody@gmail.com"]]).structured
        let first = try XCTUnwrap(firstCall?["profiles"]?.arrayValue)
        XCTAssertEqual(first[0]["department"], "Дирекция")
        XCTAssertEqual(first[0]["office"], "Г-502")
        XCTAssertEqual(first[0]["city"], "Москва")
        XCTAssertNil(first[0]["company"])
        XCTAssertEqual(first[0]["manager"]?["email"], "boss@corp.ru")
        XCTAssertEqual(first[0]["is_you"], true)
        XCTAssertEqual(first[0]["in_directory"], true)
        XCTAssertEqual(first[1]["in_directory"], false)

        _ = await tools.call(name: "get_person_profile", arguments: ["emails": ["ME@corp.ru", "nobody@gmail.com"]])
        let calls = await provider.profileCalls
        XCTAssertEqual(calls, ["me@corp.ru", "nobody@gmail.com"])
    }

    func testPersonProfileStopsAtTheFirstFailure() async throws {
        let provider = DetailsProvider(
            account: exchange, ownEmail: "me@corp.ru",
            profiles: ["a@corp.ru": profile("a@corp.ru"), "c@corp.ru": profile("c@corp.ru")], failingProfiles: ["b@corp.ru"]
        )
        let (tools, _) = makeTools(events: [], provider: provider)

        let resultCall = await tools.call(name: "get_person_profile", arguments: ["emails": ["a@corp.ru", "b@corp.ru", "c@corp.ru"]]).structured
        let profiles = try XCTUnwrap(resultCall?["profiles"]?.arrayValue)
        XCTAssertEqual(profiles[0]["title"], "Архитектор")
        XCTAssertNotNil(profiles[1]["error"])
        XCTAssertNotNil(profiles[2]["error"])
        let calls = await provider.profileCalls
        XCTAssertEqual(calls, ["a@corp.ru", "b@corp.ru"])
    }

    func testPersonProfileNeedsAddresses() async {
        let (tools, _) = makeTools(events: [])
        let missing = await tools.call(name: "get_person_profile", arguments: [:])
        XCTAssertRefusal(missing, .invalidArgument)
        let name = await tools.call(name: "get_person_profile", arguments: ["emails": ["Иванов"]])
        XCTAssertRefusal(name, .invalidArgument)
        let tooMany = await tools.call(name: "get_person_profile", arguments: ["emails": .array((0..<11).map { .string("p\($0)@corp.ru") })])
        XCTAssertRefusal(tooMany, .invalidArgument)
    }

    // MARK: - find_free_slots

    /// Whole day, every day: keeps the test independent of the display time zone the slot grid
    /// uses for working hours.
    private var allDay: [String: JSONValue] {
        ["work_start": "00:00", "work_end": "24:00", "work_days": ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]]
    }

    func testFreeSlotsAvoidEveryonesBusyTimeAndReportPeopleWithoutData() async {
        let busyFrom = date(6, 10), busyTo = date(6, 12), optionalBusy = date(6, 13)
        let provider = DetailsProvider(account: exchange, people: [ivanov], ownEmail: "me@corp.ru", busy: [
            "me@corp.ru": { _ in "0" },
            "ivanov@corp.ru": { $0 >= busyFrom && $0 < busyTo ? "2" : "0" },
            "ivanov@partner.com": { _ in "4" },
            "petrov@corp.ru": { $0 == optionalBusy ? "1" : "0" },
        ])
        // The user's own meeting at 12:00 blocks that hour too.
        let (tools, _) = makeTools(events: [event("own", day: 6, hour: 12)], provider: provider)
        _ = await tools.call(name: "find_people", arguments: ["query": "Иванов"])

        var arguments = allDay
        arguments["required"] = ["ivanov@corp.ru", "ivanov@partner.com", "nobody@corp.ru"]
        arguments["optional"] = ["petrov@corp.ru"]
        arguments["duration_minutes"] = 60
        arguments["from"] = "2026-10-06T09:00"
        arguments["to"] = "2026-10-06T14:00"
        let result = await tools.call(name: "find_free_slots", arguments: arguments)

        XCTAssertFalse(result.isError, result.errorMessage ?? "")
        let slots = result.structured?["slots"]?.arrayValue ?? []
        XCTAssertEqual(slots.map { $0["start"] }, ["2026-10-06T09:00:00+03:00", "2026-10-06T13:00:00+03:00"])
        XCTAssertEqual(slots.map { $0["optional_busy"] }, [[], ["petrov@corp.ru"]])
        let attendees = result.structured?["attendees"]?.arrayValue ?? []
        XCTAssertEqual(attendees.map { $0["availability"] }, ["ok", "no_data", "no_data", "ok"])
        XCTAssertEqual(attendees.first?["name"], "Иванов Иван")
        XCTAssertNotNil(result.structured?["note"]?.stringValue)
    }

    func testFreeSlotsNeedPeopleAndADuration() async {
        let (tools, _) = makeTools(events: [])
        let noPeople = await tools.call(name: "find_free_slots", arguments: ["duration_minutes": 30])
        XCTAssertRefusal(noPeople, .invalidArgument)
        let noDuration = await tools.call(name: "find_free_slots", arguments: ["required": ["a@corp.ru"]])
        XCTAssertRefusal(noDuration, .invalidArgument)
        let past = await tools.call(name: "find_free_slots", arguments: ["required": ["a@corp.ru"], "duration_minutes": 30, "to": "2026-10-05T10:00"])
        XCTAssertRefusal(past, .invalidArgument)
    }

    func testFreeSlotsStayWithinCoverage() async {
        let provider = DetailsProvider(account: exchange, ownEmail: "me@corp.ru", busy: ["a@corp.ru": { _ in "0" }, "me@corp.ru": { _ in "0" }])
        let (tools, _) = makeTools(events: [], provider: provider)

        let beyond = await tools.call(name: "find_free_slots", arguments: ["required": ["a@corp.ru"], "duration_minutes": 30, "from": "2026-11-20", "to": "2026-11-27"])
        XCTAssertRefusal(beyond, .invalidArgument)
        XCTAssertTrue(beyond.errorMessage?.contains("only holds meetings") == true)

        let clipped = await tools.call(name: "find_free_slots", arguments: ["required": ["a@corp.ru"], "duration_minutes": 30, "from": "2026-11-01", "to": "2026-11-10"]).structured
        XCTAssertEqual(clipped?["range"]?["clipped"], true)
        XCTAssertEqual(clipped?["range"]?["to"], "2026-11-04T12:00:00+03:00")
        let calls = await provider.fetchCalls.count
        XCTAssertEqual(calls, 0)
    }

    // MARK: - create_meeting

    private var meetingArguments: [String: JSONValue] {
        [
            "title": "Синк по релизу",
            "start": "2026-10-06T15:00",
            "end": "2026-10-06T15:30",
            "required": ["ivanov@corp.ru", "IVANOV@corp.ru"],
            "optional": ["ivanov@partner.com"],
        ]
    }

    // MARK: - cancel_meeting

    private let colleague = EventAttendee(name: "Иванов Иван", email: "Ivanov@corp.ru", kind: .required, response: .accepted)
    private let myself = EventAttendee(name: "Баженов Илья", email: "me@corp.ru", kind: .required, response: .accepted)
    private let guest = EventAttendee(name: "Partner", email: "guest@partner.com", kind: .optional, response: .notResponded)

    // MARK: - respond_to_meeting

    func testRespondIsOffUntilTheUserAllowsIt() async {
        let provider = DetailsProvider(account: exchange)
        let confirmer = FakeResponseConfirmer(.confirmed)
        let (tools, _) = makeTools(
            events: [event("invite", day: 6, hour: 10, response: .notResponded, organizer: "Grace Miller")],
            provider: provider, responseConfirmer: confirmer, canRespondMeetings: false
        )
        let result = await tools.call(name: "respond_to_meeting", arguments: ["event_id": "invite", "response": "accept"])
        XCTAssertRefusal(result, .settingDisabled)
        XCTAssertTrue(confirmer.proposals.isEmpty)
        let responses = await provider.responses
        XCTAssertTrue(responses.isEmpty)
    }

    func testRespondAsksTheUserAndAnswersTheOccurrence() async {
        let provider = DetailsProvider(account: exchange)
        let confirmer = FakeResponseConfirmer(.confirmed)
        let (tools, service) = makeTools(
            events: [event("invite", day: 6, hour: 10, response: .notResponded, organizer: "Grace Miller", series: "uid")],
            provider: provider, responseConfirmer: confirmer
        )
        let result = await tools.call(name: "respond_to_meeting", arguments: ["event_id": "invite", "response": "tentative", "comment": "Late by ten minutes"], client: "Claude Code")

        XCTAssertFalse(result.isError, result.errorMessage ?? "")
        XCTAssertEqual(result.structured?["responded"], true)
        XCTAssertEqual(result.structured?["my_response"], "tentative")
        XCTAssertEqual(result.structured?["scope"], "occurrence")
        XCTAssertEqual(result.structured?["response_sent"], true)
        let proposal = confirmer.proposals.first
        XCTAssertEqual(proposal?.action, .tentative)
        XCTAssertEqual(proposal?.series, false)
        XCTAssertEqual(proposal?.isRecurring, true)
        XCTAssertEqual(proposal?.comment, "Late by ten minutes")
        XCTAssertEqual(proposal?.organizer, "Grace Miller")
        XCTAssertEqual(proposal?.client, "Claude Code")
        let responses = await provider.responses
        XCTAssertEqual(responses.count, 1)
        XCTAssertEqual(responses.first?.id, "invite")
        XCTAssertEqual(responses.first?.series, false)
        XCTAssertEqual(responses.first?.send, true)
        XCTAssertEqual(responses.first?.notes, "Late by ten minutes")
        XCTAssertEqual(service.events.first { $0.id == "invite" }?.responseType, .tentative, "the popover follows before the next sync")

        // The same call again: answered from the first one, nothing sent.
        let again = await tools.call(name: "respond_to_meeting", arguments: ["event_id": .string(MCPEventID.short("invite")), "response": "tentative", "comment": "Late by ten minutes"])
        XCTAssertEqual(again.structured?["duplicate"], true)
        XCTAssertEqual(confirmer.proposals.count, 1)
        let after = await provider.responses
        XCTAssertEqual(after.count, 1)
    }

    /// An occurrence that already has this answer is left alone without asking the user.
    func testRespondWithTheSameAnswerSendsNothing() async {
        let provider = DetailsProvider(account: exchange)
        let confirmer = FakeResponseConfirmer(.confirmed)
        let (tools, _) = makeTools(
            events: [event("invite", day: 6, hour: 10, response: .accepted, organizer: "Grace Miller")],
            provider: provider, responseConfirmer: confirmer
        )
        let result = await tools.call(name: "respond_to_meeting", arguments: ["event_id": "invite", "response": "accept"])
        XCTAssertFalse(result.isError, result.errorMessage ?? "")
        XCTAssertEqual(result.structured?["unchanged"], true)
        XCTAssertEqual(result.structured?["responded"], false)
        XCTAssertTrue(confirmer.proposals.isEmpty)
        let responses = await provider.responses
        XCTAssertTrue(responses.isEmpty)
    }

    func testRespondToTheSeriesWithoutTellingTheOrganizer() async {
        let provider = DetailsProvider(account: exchange)
        let confirmer = FakeResponseConfirmer(.confirmed)
        let (tools, service) = makeTools(
            events: [
                event("weekly-1", day: 6, hour: 10, response: .notResponded, organizer: "Grace Miller", series: "uid-w"),
                event("weekly-2", day: 13, hour: 10, response: .notResponded, organizer: "Grace Miller", series: "uid-w"),
                event("other", day: 7, hour: 10, response: .notResponded, organizer: "Grace Miller", series: "uid-o"),
            ],
            provider: provider, responseConfirmer: confirmer
        )
        let result = await tools.call(name: "respond_to_meeting", arguments: ["event_id": "weekly-1", "response": "accept", "scope": "series", "send_response": false])
        XCTAssertFalse(result.isError, result.errorMessage ?? "")
        XCTAssertEqual(result.structured?["scope"], "series")
        XCTAssertEqual(result.structured?["response_sent"], false)
        XCTAssertEqual(confirmer.proposals.first?.series, true)
        XCTAssertEqual(confirmer.proposals.first?.sendResponse, false)
        let responses = await provider.responses
        XCTAssertEqual(responses.first?.series, true)
        XCTAssertEqual(responses.first?.send, false)
        XCTAssertEqual(service.events.filter { $0.responseType == .accepted }.map(\.id).sorted(), ["weekly-1", "weekly-2"])
    }

    func testRespondRefusesWhatCannotBeAnswered() async {
        let provider = DetailsProvider(account: exchange)
        let confirmer = FakeResponseConfirmer(.confirmed)
        let (tools, _) = makeTools(
            events: [
                event("mine", day: 6, hour: 10, response: .organizer, isOrganizer: true),
                event("gone", day: 6, hour: 12, response: .notResponded, cancelled: true, organizer: "Grace Miller"),
                event("past", day: 5, hour: 9, response: .notResponded, organizer: "Grace Miller"),
                event("single", day: 6, hour: 14, response: .notResponded, organizer: "Grace Miller"),
            ],
            provider: provider, responseConfirmer: confirmer
        )
        let calls: [[String: JSONValue]] = [
            ["event_id": "mine", "response": "accept"],
            ["event_id": "gone", "response": "accept"],
            ["event_id": "past", "response": "accept"],
            ["event_id": "single", "response": "accept", "scope": "series"],
            ["event_id": "single", "response": "accept", "comment": "Hi", "send_response": false],
            ["event_id": "single", "response": "maybe"],
            ["event_id": "unknown-id", "response": "accept"],
        ]
        let codes: [MCPErrorCode] = [.notInvitation, .notInvitation, .pastEvent, .invalidArgument, .invalidArgument, .invalidArgument, .notFound]
        for (arguments, code) in zip(calls, codes) {
            let result = await tools.call(name: "respond_to_meeting", arguments: arguments)
            XCTAssertRefusal(result, code, "\(arguments)")
        }
        XCTAssertTrue(confirmer.proposals.isEmpty)
        let responses = await provider.responses
        XCTAssertTrue(responses.isEmpty)
    }

    func testRespondDeclinedByTheUserSendsNothing() async {
        let provider = DetailsProvider(account: exchange)
        let confirmer = FakeResponseConfirmer(.rejected)
        let (tools, service) = makeTools(
            events: [event("invite", day: 6, hour: 10, response: .notResponded, organizer: "Grace Miller")],
            provider: provider, responseConfirmer: confirmer
        )
        let result = await tools.call(name: "respond_to_meeting", arguments: ["event_id": "invite", "response": "decline"])
        XCTAssertRefusal(result, .userDeclined)
        XCTAssertEqual(confirmer.proposals.count, 1)
        let responses = await provider.responses
        XCTAssertTrue(responses.isEmpty)
        XCTAssertEqual(service.events.first?.responseType, .notResponded)
    }

    func testRespondFailureRestoresTheAnswer() async {
        let provider = DetailsProvider(account: exchange, removeError: OWAError.ewsError("ErrorIrresolvableConflict"))
        let confirmer = FakeResponseConfirmer(.confirmed)
        let (tools, service) = makeTools(
            events: [event("invite", day: 6, hour: 10, response: .notResponded, organizer: "Grace Miller")],
            provider: provider, responseConfirmer: confirmer
        )
        let result = await tools.call(name: "respond_to_meeting", arguments: ["event_id": "invite", "response": "accept"])
        XCTAssertRefusal(result, .stale)
        XCTAssertEqual(service.events.first?.responseType, .notResponded)
    }

    // MARK: - Error codes

    func testRespondErrorsFromExchangeCarryTheirCode() async {
        let cases: [(Error, MCPErrorCode)] = [
            (URLError(.networkConnectionLost), .unconfirmed),
            (URLError(.timedOut), .unconfirmed),
            (URLError(.notConnectedToInternet), .offline),
            (OWAError.ewsError("ErrorItemNotFound"), .notFound),
            (OWAError.ewsError("ErrorAccessDenied"), .exchangeError),
            (OWAError.authenticationFailed("rejected"), .authFailed),
        ]
        for (error, code) in cases {
            let provider = DetailsProvider(account: exchange, removeError: error)
            let (tools, _) = makeTools(
                events: [event("invite", day: 6, hour: 10, response: .notResponded, organizer: "Grace Miller")],
                provider: provider, responseConfirmer: FakeResponseConfirmer(.confirmed)
            )
            let result = await tools.call(name: "respond_to_meeting", arguments: ["event_id": "invite", "response": "accept", "send_response": false])
            XCTAssertRefusal(result, code, "\(error)")
        }
    }

    func testAnotherOpenPanelIsBusy() async {
        let confirmer = HoldingResponseConfirmer()
        let (held, _) = makeTools(events: [
            event("first", day: 6, hour: 10, response: .notResponded, organizer: "Grace Miller"),
            event("second", day: 6, hour: 12, response: .notResponded, organizer: "Grace Miller"),
        ], responseConfirmer: confirmer)
        let waiting = Task { await held.call(name: "respond_to_meeting", arguments: ["event_id": "first", "response": "accept"]) }
        while confirmer.proposals.isEmpty { await Task.yield() }

        let second = await held.call(name: "respond_to_meeting", arguments: ["event_id": "second", "response": "accept"])
        XCTAssertRefusal(second, .busy)
        confirmer.release(.rejected)
        let first = await waiting.value
        XCTAssertRefusal(first, .userDeclined)
    }

    func testSettingRefusalNamesTheSwitch() async throws {
        let (tools, _) = makeTools(events: [event("invite", day: 6, hour: 10, response: .notResponded, organizer: "Grace Miller")], canRespondMeetings: false)
        let result = await tools.call(name: "respond_to_meeting", arguments: ["event_id": "invite", "response": "accept"])
        XCTAssertRefusal(result, .settingDisabled)
        let json = result.json["structuredContent"]
        XCTAssertEqual(json?["error_code"], "setting_disabled")
        XCTAssertEqual(json?["setting_id"], "respond_meetings")
        let title = try XCTUnwrap(json?["setting"]?.stringValue)
        XCTAssertTrue(["Allow answering invitations", "Разрешить отвечать на приглашения"].contains(title), title)
    }

    func testBlockedSyncRefusesWithItsCode() async {
        let (tools, service) = makeTools(events: [], provider: DetailsProvider(account: exchange, people: [me]))
        service.debugForceAuthBlock()
        XCTAssertRefusal(await tools.call(name: "find_people", arguments: ["query": "Иванов"]), .authFailed)
        XCTAssertEqual(MCPAccessGuard.blockError(.certificateTrustRequired(host: "mail", fingerprint: "ab"))?.code, .trustRequired)
        XCTAssertEqual(MCPAccessGuard.blockError(.loginHostApprovalRequired(configuredHost: "mail", loginHost: "sso"))?.code, .trustRequired)
        XCTAssertNil(MCPAccessGuard.blockError(.idle))
    }

    func testNoSyncYetIsNotReady() async {
        let (tools, service) = makeTools(events: [])
        service.setEventCoverageForTests(nil)
        XCTAssertRefusal(await tools.call(name: "list_events", arguments: [:]), .notReady)
    }

    func testRespondPayloadFollowsOWA() throws {
        let occurrence = OWARespondToCalendarEventPayload.json(
            itemID: "OCC", changeKey: "CK", series: false, action: .tentative, notes: "a < b\n\nok", sendResponse: true, timeZoneID: "Russian Standard Time"
        )
        let body = try XCTUnwrap(occurrence["Body"] as? [String: Any])
        XCTAssertEqual(occurrence["__type"] as? String, "RespondToCalendarEventJsonRequest:#Exchange")
        XCTAssertEqual(body["Response"] as? String, "Tentative")
        XCTAssertEqual(body["SendResponse"] as? Bool, true)
        let eventID = try XCTUnwrap(body["EventId"] as? [String: Any])
        XCTAssertEqual(eventID["__type"] as? String, "ItemId:#Exchange")
        XCTAssertEqual(eventID["Id"] as? String, "OCC")
        XCTAssertEqual(eventID["ChangeKey"] as? String, "CK")
        let notes = try XCTUnwrap((body["Notes"] as? [String: Any])?["Value"] as? String)
        XCTAssertTrue(notes.contains("<div>a &lt; b</div><div><br></div><div>ok</div>"), notes)

        let series = OWARespondToCalendarEventPayload.json(
            itemID: "OCC", changeKey: "CK", series: true, action: .decline, notes: "", sendResponse: false, timeZoneID: "UTC"
        )
        let seriesBody = try XCTUnwrap(series["Body"] as? [String: Any])
        let master = try XCTUnwrap(seriesBody["EventId"] as? [String: Any])
        XCTAssertEqual(master["__type"] as? String, "RecurringMasterItemId:#Exchange")
        XCTAssertEqual(master["OccurrenceId"] as? String, "OCC")
        XCTAssertNil(master["Id"])
        XCTAssertEqual(seriesBody["Response"] as? String, "Decline")
        XCTAssertEqual(seriesBody["SendResponse"] as? Bool, false)

        XCTAssertNoThrow(try OWARespondToCalendarEventPayload.check(Data(#"{"Body":{"ResponseCode":"NoError","ResponseClass":"Success"}}"#.utf8)))
        XCTAssertThrowsError(try OWARespondToCalendarEventPayload.check(Data(#"{"Body":{"ResponseCode":"ErrorItemNotFound","ResponseClass":"Error"}}"#.utf8)))
    }

    func testCancelMeetingIsOffUntilTheUserAllowsIt() async {
        let provider = DetailsProvider(account: exchange)
        let confirmer = FakeRemovalConfirmer(.confirmed)
        let (tools, _) = makeTools(
            events: [event("sync", day: 6, hour: 10, isOrganizer: true, attendees: [colleague])],
            provider: provider, removalConfirmer: confirmer, canRemoveMeetings: false
        )

        let result = await tools.call(name: "cancel_meeting", arguments: ["event_id": "sync"])

        XCTAssertRefusal(result, .settingDisabled)
        XCTAssertTrue(confirmer.proposals.isEmpty)
        let removed = await provider.removed
        XCTAssertTrue(removed.isEmpty)
    }

    func testOrganizerCancelsForEveryAttendeeButThemselves() async {
        let provider = DetailsProvider(account: exchange, ownEmail: "me@corp.ru")
        let confirmer = FakeRemovalConfirmer(.confirmed)
        let (tools, service) = makeTools(
            events: [event("sync", day: 6, hour: 10, isOrganizer: true, attendees: [myself, colleague, guest], series: "uid")],
            provider: provider, removalConfirmer: confirmer
        )

        let result = await tools.call(name: "cancel_meeting", arguments: ["event_id": "sync", "message": "Переносим"], client: "Claude Code")

        XCTAssertFalse(result.isError, result.errorMessage ?? "")
        XCTAssertEqual(result.structured?["removed"], true)
        XCTAssertEqual(result.structured?["action"], "cancelled")
        XCTAssertEqual(result.structured?["cancellation_sent_to"], ["ivanov@corp.ru", "guest@partner.com"])
        XCTAssertEqual(result.structured?["occurrence_only"], true)
        let proposal = confirmer.proposals.first
        XCTAssertEqual(proposal?.mode, .cancelForAttendees)
        XCTAssertEqual(proposal?.client, "Claude Code")
        XCTAssertEqual(proposal?.attendees.map(\.email), ["ivanov@corp.ru", "guest@partner.com"])
        XCTAssertEqual(proposal?.attendees.map(\.isExternal), [false, true])
        XCTAssertEqual(proposal?.isOccurrence, true)
        let removed = await provider.removed
        XCTAssertEqual(removed.map(\.id), ["sync"])
        XCTAssertEqual(removed.first?.mode, .cancelForAttendees)
        XCTAssertEqual(removed.first?.message, "Переносим")
        // Gone from the popover before the next sync.
        XCTAssertFalse(service.events.contains { $0.id == "sync" })
    }

    func testRepeatedCancelReturnsTheFirstResult() async {
        let provider = DetailsProvider(account: exchange)
        let confirmer = FakeRemovalConfirmer(.confirmed)
        let (tools, _) = makeTools(
            events: [event("sync", day: 6, hour: 10, isOrganizer: true, attendees: [colleague])],
            provider: provider, removalConfirmer: confirmer
        )

        _ = await tools.call(name: "cancel_meeting", arguments: ["event_id": "sync"])
        let second = await tools.call(name: "cancel_meeting", arguments: ["event_id": .string(MCPEventID.short("sync"))])

        XCTAssertEqual(second.structured?["duplicate"], true)
        XCTAssertEqual(confirmer.proposals.count, 1)
        let removed = await provider.removed
        XCTAssertEqual(removed.count, 1)
    }

    func testOrganizerWithoutAttendeesOnlyDeletes() async {
        let provider = DetailsProvider(account: exchange, ownEmail: "me@corp.ru")
        let confirmer = FakeRemovalConfirmer(.confirmed)
        let (tools, _) = makeTools(
            events: [event("focus", day: 6, hour: 10, isOrganizer: true, attendees: [myself])],
            provider: provider, removalConfirmer: confirmer
        )

        let result = await tools.call(name: "cancel_meeting", arguments: ["event_id": "focus"])

        XCTAssertEqual(result.structured?["action"], "deleted")
        XCTAssertEqual(confirmer.proposals.first?.mode, .deleteSilently)
        let removed = await provider.removed
        XCTAssertEqual(removed.first?.mode, .deleteSilently)
    }

    func testOrganizerWithoutAttendeeListIsNotAsked() async {
        let provider = DetailsProvider(account: exchange, error: URLError(.timedOut))
        let confirmer = FakeRemovalConfirmer(.confirmed)
        let (tools, _) = makeTools(events: [event("sync", day: 6, hour: 10, isOrganizer: true)], provider: provider, removalConfirmer: confirmer)

        let result = await tools.call(name: "cancel_meeting", arguments: ["event_id": "sync"])

        XCTAssertRefusal(result, .exchangeError)
        XCTAssertTrue(result.errorMessage?.contains("Nothing was changed") == true)
        XCTAssertTrue(confirmer.proposals.isEmpty)
    }

    func testInvitationIsDeclinedOrDeletedSilently() async {
        let provider = DetailsProvider(account: exchange)
        let confirmer = FakeRemovalConfirmer(.confirmed)
        let (tools, _) = makeTools(events: [
            event("invite", day: 6, hour: 10, organizer: "Петров Пётр"),
            event("other", day: 6, hour: 12, organizer: "Петров Пётр"),
        ], provider: provider, removalConfirmer: confirmer)

        let declined = await tools.call(name: "cancel_meeting", arguments: ["event_id": "invite", "message": "Не смогу"])
        let deleted = await tools.call(name: "cancel_meeting", arguments: ["event_id": "other", "notify_organizer": false])

        XCTAssertEqual(declined.structured?["action"], "declined")
        XCTAssertEqual(deleted.structured?["action"], "deleted")
        XCTAssertEqual(confirmer.proposals.map(\.mode), [.decline, .deleteSilently])
        XCTAssertEqual(confirmer.proposals.first?.organizer, "Петров Пётр")
        let removed = await provider.removed
        XCTAssertEqual(removed.map(\.mode), [.decline, .deleteSilently])
        XCTAssertEqual(removed.first?.message, "Не смогу")
    }

    func testMessageIsRefusedWhenNobodyIsTold() async {
        let provider = DetailsProvider(account: exchange)
        let confirmer = FakeRemovalConfirmer(.confirmed)
        let (tools, _) = makeTools(events: [event("gone", day: 6, hour: 10, cancelled: true)], provider: provider, removalConfirmer: confirmer)

        let result = await tools.call(name: "cancel_meeting", arguments: ["event_id": "gone", "message": "Пока"])

        XCTAssertRefusal(result, .invalidArgument)
        XCTAssertTrue(confirmer.proposals.isEmpty)
    }

    func testMeetingAlreadyCancelledByTheOrganizerIsDeleted() async {
        let provider = DetailsProvider(account: exchange)
        let confirmer = FakeRemovalConfirmer(.confirmed)
        let (tools, _) = makeTools(events: [event("gone", day: 6, hour: 10, cancelled: true)], provider: provider, removalConfirmer: confirmer)

        _ = await tools.call(name: "cancel_meeting", arguments: ["event_id": "gone"])

        XCTAssertEqual(confirmer.proposals.first?.mode, .deleteSilently)
        XCTAssertEqual(confirmer.proposals.first?.isAlreadyCancelled, true)
    }

    func testPastAndLocalMeetingsAreRefused() async {
        let provider = DetailsProvider(account: exchange)
        let confirmer = FakeRemovalConfirmer(.confirmed)
        let (tools, _) = makeTools(events: [
            event("past", day: 5, hour: 9),
            event("local", day: 6, hour: 10, account: local),
        ], provider: provider, removalConfirmer: confirmer)

        for (id, code) in [("past", MCPErrorCode.pastEvent), ("local", .notSupported), ("missing", .notFound)] {
            let result = await tools.call(name: "cancel_meeting", arguments: ["event_id": .string(id)])
            XCTAssertRefusal(result, code, id)
        }
        XCTAssertTrue(confirmer.proposals.isEmpty)
    }

    func testDeclinedOrUnansweredConfirmationChangesNothing() async {
        for outcome in [MCPConfirmationOutcome.rejected, .timedOut, .cancelled] {
            let provider = DetailsProvider(account: exchange)
            let (tools, service) = makeTools(
                events: [event("invite", day: 6, hour: 10)],
                provider: provider, removalConfirmer: FakeRemovalConfirmer(outcome)
            )

            let result = await tools.call(name: "cancel_meeting", arguments: ["event_id": "invite"])

            XCTAssertRefusal(result, outcome.refusalCode, "\(outcome)")
            XCTAssertTrue(result.errorMessage?.contains("Nothing was changed") == true, "\(outcome)")
            let removed = await provider.removed
            XCTAssertTrue(removed.isEmpty, "\(outcome)")
            XCTAssertTrue(service.events.contains { $0.id == "invite" }, "\(outcome)")
        }
    }

    func testStaleMeetingIsReportedAndKept() async {
        let provider = DetailsProvider(account: exchange, removeError: OWAError.ewsError("ErrorIrresolvableConflict"))
        let (tools, service) = makeTools(
            events: [event("invite", day: 6, hour: 10)],
            provider: provider, removalConfirmer: FakeRemovalConfirmer(.confirmed)
        )

        let result = await tools.call(name: "cancel_meeting", arguments: ["event_id": "invite"])

        XCTAssertRefusal(result, .stale)
        XCTAssertTrue(result.errorMessage?.contains("changed in Exchange") == true)
        XCTAssertTrue(service.events.contains { $0.id == "invite" })
    }

    func testNameOnlyAttendeesStillGetTheCancellation() async {
        let list = EventAttendee(name: "Команда релиза", email: nil, kind: .required, response: .notResponded)
        let provider = DetailsProvider(account: exchange)
        let confirmer = FakeRemovalConfirmer(.confirmed)
        let (tools, _) = makeTools(
            events: [event("sync", day: 6, hour: 10, isOrganizer: true, attendees: [list])],
            provider: provider, removalConfirmer: confirmer
        )

        let result = await tools.call(name: "cancel_meeting", arguments: ["event_id": "sync"])

        XCTAssertEqual(result.structured?["action"], "cancelled")
        XCTAssertEqual(result.structured?["cancellation_sent_to"], ["Команда релиза"])
        XCTAssertEqual(confirmer.proposals.first?.mode, .cancelForAttendees)
        XCTAssertEqual(confirmer.proposals.first?.unaddressedAttendees, ["Команда релиза"])
        let removed = await provider.removed
        XCTAssertEqual(removed.first?.mode, .cancelForAttendees)
    }

    func testOrganizersOwnCancelledLookingTitleIsCancelledForEveryone() async {
        let provider = DetailsProvider(account: exchange)
        let confirmer = FakeRemovalConfirmer(.confirmed)
        let meeting = CalendarEvent(
            id: "cancelled-title", title: "Cancelled: разбор Q3", startDate: date(6, 10), endDate: date(6, 11),
            location: nil, bodyPreview: nil, joinURL: nil, platform: .generic, isAllDay: false, organizer: nil,
            accountID: exchange.id, isCancelled: false, isOrganizer: true, changeKey: "ck", detailedAttendees: [colleague]
        )
        let (tools, _) = makeTools(events: [meeting], provider: provider, removalConfirmer: confirmer)

        _ = await tools.call(name: "cancel_meeting", arguments: ["event_id": "cancelled-title"])

        XCTAssertEqual(confirmer.proposals.first?.mode, .cancelForAttendees)
        XCTAssertEqual(confirmer.proposals.first?.isAlreadyCancelled, false)
    }

    func testOrganizerEntryIsNotACancellationRecipient() {
        let organizerEntry = EventAttendee(name: "Баженов Илья", email: "me@corp.ru", kind: .required, response: .organizer)
        let nameless = EventAttendee(name: "Рассылка", email: nil, kind: .optional, response: .notResponded)

        // Own address unknown: the organizer is still recognised by the response Exchange gives it.
        let (addressed, unaddressed) = MCPCalendarTools.cancellationRecipients(
            [organizerEntry, colleague, colleague, nameless, nameless], ownAddress: nil, ownDomain: "corp.ru"
        )

        XCTAssertEqual(addressed.map(\.email), ["ivanov@corp.ru"])
        XCTAssertEqual(unaddressed, ["Рассылка"])
        let own = MCPCalendarTools.cancellationRecipients([myself], ownAddress: "ME@corp.ru", ownDomain: nil)
        XCTAssertTrue(own.addressed.isEmpty && own.unaddressed.isEmpty)
    }

    func testAlreadyDeclinedInvitationIsDeletedWithoutASecondDecline() async {
        let provider = DetailsProvider(account: exchange)
        let confirmer = FakeRemovalConfirmer(.confirmed)
        let (tools, _) = makeTools(
            events: [event("invite", day: 6, hour: 10, response: .declined, organizer: "Петров Пётр")],
            provider: provider, removalConfirmer: confirmer
        )

        let result = await tools.call(name: "cancel_meeting", arguments: ["event_id": "invite"])

        XCTAssertEqual(result.structured?["action"], "deleted")
        XCTAssertEqual(confirmer.proposals.first?.mode, .deleteSilently)
        XCTAssertEqual(confirmer.proposals.first?.isAlreadyDeclined, true)
    }

    func testPanelTimeLeavesRoomForTheClientsDeadline() async {
        // The attendee list took 12 seconds: the panel gets what is left of the 50-second budget.
        var ticks: [TimeInterval] = [0, 12]
        let confirmer = FakeRemovalConfirmer(.rejected)
        let (tools, _) = makeTools(
            events: [event("sync", day: 6, hour: 10, isOrganizer: true, attendees: [colleague])],
            removalConfirmer: confirmer,
            uptime: { ticks.isEmpty ? 12 : ticks.removeFirst() }
        )

        _ = await tools.call(name: "cancel_meeting", arguments: ["event_id": "sync"])

        XCTAssertEqual(confirmer.timeouts, [38])
    }

    func testTooSlowExchangeLeavesNoPanel() async {
        var ticks: [TimeInterval] = [0, 35]
        let confirmer = FakeRemovalConfirmer(.confirmed)
        let provider = DetailsProvider(account: exchange)
        let (tools, _) = makeTools(
            events: [event("sync", day: 6, hour: 10, isOrganizer: true, attendees: [colleague])],
            provider: provider, removalConfirmer: confirmer,
            uptime: { ticks.isEmpty ? 35 : ticks.removeFirst() }
        )

        let result = await tools.call(name: "cancel_meeting", arguments: ["event_id": "sync"])

        XCTAssertRefusal(result, .exchangeError)
        XCTAssertTrue(result.errorMessage?.contains("Nothing was changed") == true)
        XCTAssertTrue(confirmer.proposals.isEmpty)
        let removed = await provider.removed
        XCTAssertTrue(removed.isEmpty)
    }

    // MARK: - find_people with several names

    func testSeveralNamesAreLookedUpInOneCall() async {
        let provider = DetailsProvider(account: exchange, people: [ivanov, partner, me, namesake], ownEmail: "me@corp.ru")
        let (tools, _) = makeTools(events: [], provider: provider)

        let result = await tools.call(name: "find_people", arguments: [
            "queries": ["Иванов", "Баженов", "иванов", "Сидоров"],
        ]).structured

        XCTAssertNil(result?["people"])
        let groups = result?["results"]?.arrayValue ?? []
        // The repeated name is looked up once.
        XCTAssertEqual(groups.map { $0["query"] }, ["Иванов", "Баженов", "Сидоров"])
        XCTAssertEqual(groups[0]["people"]?.arrayValue?.map { $0["email"] }, ["ivanov@corp.ru"])
        XCTAssertEqual(groups[1]["people"]?.arrayValue?.filter { $0["is_you"] == true }.count, 1)
        XCTAssertEqual(groups[2]["total"], 0)
        let searches = await provider.peopleSearches
        XCTAssertEqual(searches.count, 3)
        let lookups = await provider.ownEmailCalls
        XCTAssertEqual(lookups, 1)
    }

    func testOneFailedNameDoesNotSinkTheOthers() async {
        let provider = DetailsProvider(account: exchange, people: [ivanov], failingSearches: ["Петров"])
        let (tools, _) = makeTools(events: [], provider: provider)

        let result = await tools.call(name: "find_people", arguments: ["queries": ["Петров", "Иванов"]])

        XCTAssertFalse(result.isError, result.errorMessage ?? "")
        let groups = result.structured?["results"]?.arrayValue ?? []
        XCTAssertNotNil(groups[0]["error"])
        XCTAssertNil(groups[0]["people"])
        XCTAssertEqual(groups[1]["people"]?.arrayValue?.count, 1)
    }

    func testSeveralNamesAreChargedUpFrontOrNotAtAll() async {
        let provider = DetailsProvider(account: exchange, people: [ivanov])
        let (tools, _) = makeTools(events: [], provider: provider)
        // Eight words per name: 9 requests each, 90 in all — more than a minute's budget.
        let long = (0..<10).map { "Иван\($0) Ив Ива Иванов Петр Пётр Сидор Сидоров" }

        let result = await tools.call(name: "find_people", arguments: ["queries": .array(long.map(JSONValue.string))])

        XCTAssertRefusal(result, .rateLimited)
        let searches = await provider.peopleSearches
        XCTAssertTrue(searches.isEmpty)
    }

    func testFindPeopleTakesExactlyOneKindOfQuery() async {
        let (tools, _) = makeTools(events: [])
        let broken: [[String: JSONValue]] = [
            [:],
            ["query": "Иванов", "queries": ["Петров"]],
            ["queries": []],
            ["queries": ["Иванов", "П"]],
            ["queries": .array((0..<11).map { .string("Имя\($0)") })],
            ["queries": "Иванов"],
        ]
        for arguments in broken {
            let result = await tools.call(name: "find_people", arguments: arguments)
            XCTAssertRefusal(result, .invalidArgument, "\(arguments)")
        }
    }

    func testCreateMeetingIsOffUntilTheUserAllowsIt() async {
        let provider = DetailsProvider(account: exchange)
        let confirmer = FakeConfirmer(.confirmed)
        let (tools, _) = makeTools(events: [], provider: provider, confirmer: confirmer, canCreateMeetings: false)

        let result = await tools.call(name: "create_meeting", arguments: meetingArguments)

        XCTAssertRefusal(result, .settingDisabled)
        XCTAssertTrue(confirmer.proposals.isEmpty)
        let created = await provider.created
        XCTAssertTrue(created.isEmpty)
    }

    func testCreateMeetingShowsTheMeetingAndCreatesItOnlyAfterConfirmation() async {
        let provider = DetailsProvider(account: exchange, people: [ivanov, partner], ownEmail: "me@corp.ru")
        let confirmer = FakeConfirmer(.confirmed)
        let (tools, _) = makeTools(events: [
            event("busy", day: 6, hour: 15),
            event("declined", day: 6, hour: 15, response: .declined),
        ], provider: provider, confirmer: confirmer)
        _ = await tools.call(name: "find_people", arguments: ["query": "Ivanov"])

        let result = await tools.call(name: "create_meeting", arguments: meetingArguments, client: "Claude Code")

        XCTAssertFalse(result.isError, result.errorMessage ?? "")
        XCTAssertEqual(result.structured?["created"], true)
        XCTAssertEqual(result.structured?["invitations_sent"], true)
        let proposal = confirmer.proposals.first
        XCTAssertEqual(proposal?.client, "Claude Code")
        XCTAssertEqual(proposal?.start, date(6, 15))
        // Duplicates collapse; names come from the address book; the partner is flagged.
        XCTAssertEqual(proposal?.required, [.init(email: "ivanov@corp.ru", name: "Иванов Иван", isExternal: false)])
        XCTAssertEqual(proposal?.optional, [.init(email: "ivanov@partner.com", name: "Partner Ivanov", isExternal: true)])
        // A declined meeting is not a conflict.
        XCTAssertEqual(proposal?.conflicts.map(\.title), ["busy"])
        let created = await provider.created
        XCTAssertEqual(created.map(\.title), ["Синк по релизу"])
        XCTAssertEqual(created.first?.required, ["ivanov@corp.ru"])
        XCTAssertEqual(created.first?.optional, ["ivanov@partner.com"])
    }

    func testDeclinedOrUnansweredConfirmationCreatesNothing() async {
        for outcome in [MCPConfirmationOutcome.rejected, .timedOut, .cancelled] {
            let provider = DetailsProvider(account: exchange)
            let (tools, _) = makeTools(events: [], provider: provider, confirmer: FakeConfirmer(outcome))

            let result = await tools.call(name: "create_meeting", arguments: meetingArguments)

            XCTAssertRefusal(result, outcome.refusalCode, "\(outcome)")
            XCTAssertTrue(result.errorMessage?.contains("Nothing was created") == true, "\(outcome)")
            let created = await provider.created
            XCTAssertTrue(created.isEmpty, "\(outcome)")
        }
    }

    func testRepeatedCallReturnsTheFirstMeetingInsteadOfASecondOne() async {
        let provider = DetailsProvider(account: exchange)
        let confirmer = FakeConfirmer(.confirmed)
        let (tools, _) = makeTools(events: [], provider: provider, confirmer: confirmer)

        _ = await tools.call(name: "create_meeting", arguments: meetingArguments)
        let second = await tools.call(name: "create_meeting", arguments: meetingArguments).structured

        XCTAssertEqual(second?["duplicate"], true)
        XCTAssertEqual(confirmer.proposals.count, 1)
        let created = await provider.created
        XCTAssertEqual(created.count, 1)
    }

    func testEditHandsTheMeetingToTheWindowWithoutCreatingIt() async {
        let provider = DetailsProvider(account: exchange, people: [ivanov, partner], ownEmail: "me@corp.ru")
        let confirmer = FakeConfirmer(.handedOff)
        var seeds: [MeetingDraftSeed] = []
        let (tools, _) = makeTools(events: [], provider: provider, confirmer: confirmer, handOff: { seeds.append($0) })
        _ = await tools.call(name: "find_people", arguments: ["query": "Ivanov"])
        var arguments = meetingArguments
        arguments["agenda"] = "План релиза"

        let result = await tools.call(name: "create_meeting", arguments: arguments, client: "Claude Code")

        // Settled, not failed: an error would make the model try again.
        XCTAssertFalse(result.isError, result.errorMessage ?? "")
        XCTAssertEqual(result.structured?["created"], false)
        XCTAssertEqual(result.structured?["handed_off"], true)
        let created = await provider.created
        XCTAssertTrue(created.isEmpty)

        XCTAssertEqual(seeds.count, 1)
        let seed = seeds.first
        XCTAssertEqual(seed?.title, "Синк по релизу")
        XCTAssertEqual(seed?.agenda, "План релиза")
        XCTAssertEqual(seed?.slot, DateInterval(start: date(6, 15), end: date(6, 15, 30)))
        XCTAssertEqual(seed?.accountID, exchange.id)
        XCTAssertEqual(seed?.client, "Claude Code")
        XCTAssertEqual(seed?.required.map(\.email), ["ivanov@corp.ru"])
        XCTAssertEqual(seed?.required.map(\.displayName), ["Иванов Иван"])
        XCTAssertEqual(seed?.optional.map(\.email), ["ivanov@partner.com"])

        // The model repeating itself gets the same answer, not a second window.
        let again = await tools.call(name: "create_meeting", arguments: arguments, client: "Claude Code").structured
        XCTAssertEqual(again?["duplicate"], true)
        XCTAssertEqual(again?["handed_off"], true)
        XCTAssertEqual(seeds.count, 1)
        XCTAssertEqual(confirmer.proposals.count, 1)
    }

    func testCreateMeetingRejectsBadArgumentsBeforeAskingTheUser() async {
        let confirmer = FakeConfirmer(.confirmed)
        let (tools, _) = makeTools(events: [], confirmer: confirmer)
        let broken: [[String: JSONValue]] = [
            ["title": "x", "start": "2026-10-06", "end": "2026-10-06T15:30"],
            ["title": "x", "start": "2026-10-05T09:00", "end": "2026-10-05T09:30"],
            ["title": "x", "start": "2026-10-06T15:00", "end": "2026-10-06T14:00"],
            ["title": "x", "start": "2026-10-06T15:00", "end": "2026-10-08T15:00"],
            ["title": " ", "start": "2026-10-06T15:00", "end": "2026-10-06T15:30"],
            ["title": "x", "start": "2026-10-06T15:00", "end": "2026-10-06T15:30", "required": ["Иванов"]],
            ["title": "x", "start": "2026-10-06T15:00", "end": "2026-10-06T15:30", "account_id": .string(local.id.uuidString)],
            ["title": "Созвон \u{202E}", "start": "2026-10-06T15:00", "end": "2026-10-06T15:30"],
            ["title": "x", "start": "2026-10-06T15:00", "end": "2026-10-06T15:30", "agenda": "итоги \u{2066}скрыто\u{2069}"],
            ["title": "Созвон\u{E0073}\u{E0065}\u{E0063}", "start": "2026-10-06T15:00", "end": "2026-10-06T15:30"],
            ["title": "x", "start": "2026-10-06T15:00", "end": "2026-10-06T15:30", "location": "Room\u{FE01}\u{E0110}"],
            ["title": "x", "start": "2026-10-06T15:00", "end": "2026-10-06T15:30", "agenda": "ито\u{200B}ги"],
            ["title": "x", "start": "2026-10-06T15:00", "end": "2026-10-06T15:30", "required": ["ivan@\u{0430}lfabank.ru"]],
        ]
        for arguments in broken {
            let result = await tools.call(name: "create_meeting", arguments: arguments)
            XCTAssertRefusal(result, arguments["account_id"] == nil ? .invalidArgument : .notSupported, "\(arguments)")
        }
        XCTAssertTrue(confirmer.proposals.isEmpty)
    }

    func testExternalAddressDetection() {
        XCTAssertFalse(MCPCalendarTools.isExternal("a@corp.ru", ownDomain: "corp.ru"))
        XCTAssertFalse(MCPCalendarTools.isExternal("a@mail.corp.ru", ownDomain: "corp.ru"))
        XCTAssertTrue(MCPCalendarTools.isExternal("a@evilcorp.ru", ownDomain: "corp.ru"))
        XCTAssertFalse(MCPCalendarTools.isExternal("a@evilcorp.ru", ownDomain: nil))
        XCTAssertFalse(MCPCalendarTools.isEmailAddress("a@b"))
        XCTAssertFalse(MCPCalendarTools.isEmailAddress("Ivan <a@b.ru>"))
        XCTAssertTrue(MCPCalendarTools.isEmailAddress("ivan.ivanov@corp.ru"))
    }

    func testUnknownOwnDomainIsSaidAloudAndNotRetriedOnEveryCall() async {
        let provider = DetailsProvider(
            account: exchange,
            people: [partner],
            ownEmailError: URLError(.timedOut)
        )
        let confirmer = FakeConfirmer(.rejected)
        let (tools, _) = makeTools(events: [], provider: provider, confirmer: confirmer)

        let search = await tools.call(name: "find_people", arguments: ["query": "Partner"]).structured
        _ = await tools.call(name: "create_meeting", arguments: meetingArguments)

        // Not "internal": unknown.
        XCTAssertEqual(search?["people"]?.arrayValue?.first?["external"], .null)
        XCTAssertEqual(confirmer.proposals.first?.externalCheckAvailable, false)
        let lookups = await provider.ownEmailCalls
        XCTAssertEqual(lookups, 1)
    }

    func testOwnDomainLookupFailureIsRetriedAfterAMinuteNotTen() async {
        var current = now
        let provider = DetailsProvider(account: exchange, people: [partner], ownEmailError: URLError(.timedOut))
        let service = CalendarService(
            providers: [provider],
            notificationService: SilentNotificationService(),
            customMeetingReminders: SilentMeetingReminderController(),
            loadPersistedAccounts: false,
            startBackgroundTasks: false,
            clock: { [now] in now }
        )
        service.replaceAccountsForTests([exchange])
        service.setEventCoverageForTests(EventCoverage(start: date(1, 0), end: date(30, 0), refreshedAt: now))
        let tools = MCPCalendarTools(calendarService: service, clock: { current }, timeZone: { [zone] in zone })

        _ = await tools.call(name: "find_people", arguments: ["query": "Partner"])
        current = now.addingTimeInterval(30)
        _ = await tools.call(name: "find_people", arguments: ["query": "Partner"])
        var lookups = await provider.ownEmailCalls
        XCTAssertEqual(lookups, 1)

        current = now.addingTimeInterval(61)
        _ = await tools.call(name: "find_people", arguments: ["query": "Partner"])
        lookups = await provider.ownEmailCalls
        XCTAssertEqual(lookups, 2)
    }

    func testFindPeopleBudgetCountsEveryRequestItMayMake() {
        XCTAssertEqual(MCPCalendarTools.findPeopleRequestCost("Иванов"), 1)
        XCTAssertEqual(MCPCalendarTools.findPeopleRequestCost("Иван Иванов"), 3)
        XCTAssertEqual(MCPCalendarTools.findPeopleRequestCost("Иван И"), 1)
        var bucket = MCPTokenBucket(capacity: 3, perMinute: 3, now: now)
        XCTAssertFalse(bucket.take(4, now: now))
        XCTAssertTrue(bucket.take(3, now: now))
        XCTAssertFalse(bucket.take(now: now))
    }

    func testConfirmationPanelAlwaysShowsExternalAttendees() {
        let internalPeople = (0..<12).map { MCPMeetingProposal.Attendee(email: "p\($0)@corp.ru", name: nil, isExternal: false) }
        let outsider = MCPMeetingProposal.Attendee(email: "x@evil.com", name: nil, isExternal: true)
        let visible = MCPMeetingConfirmationView.visibleAttendees(internalPeople + [outsider])
        XCTAssertEqual(visible.count, MCPMeetingConfirmationView.visibleAttendeeLimit)
        XCTAssertEqual(visible.first, outsider)
    }
}

/// `data_as_of` must not claim a fresh calendar when part of it failed to sync.
@MainActor
final class CalendarServiceCoverageTests: XCTestCase {
    private actor Provider: CalendarProvider {
        nonisolated let account: CalendarAccount
        private let error: Error?

        init(account: CalendarAccount, error: Error? = nil) {
            self.account = account
            self.error = error
        }

        func fetchEvents(from start: Date, to end: Date) async throws -> [CalendarEvent] {
            if let error { throw error }
            let startDate = Date().addingTimeInterval(3600)
            return [CalendarEvent(
                id: "\(account.id)", title: "x", startDate: startDate, endDate: startDate.addingTimeInterval(1800),
                location: nil, bodyPreview: nil, joinURL: nil, platform: .generic, isAllDay: false,
                organizer: nil, accountID: account.id
            )]
        }

        func validateCredentials() async throws {}
    }

    private func makeService(_ providers: [any CalendarProvider]) -> CalendarService {
        CalendarService(
            providers: providers,
            notificationService: SilentNotificationService(),
            customMeetingReminders: SilentMeetingReminderController(),
            loadPersistedAccounts: false,
            startBackgroundTasks: false
        )
    }

    func testFullSuccessRefreshesCoverage() async {
        let service = makeService([Provider(account: CalendarAccount(displayName: "W", serverURL: "", email: "", accountType: .owa))])
        await service.performSyncForTests()
        XCTAssertNotNil(service.eventCoverage)
        XCTAssertLessThan(abs(service.eventCoverage!.refreshedAt.timeIntervalSinceNow), 5)
    }

    func testFailedProviderKeepsTheOldTimestamp() async {
        let old = EventCoverage(start: Date().addingTimeInterval(-86400 * 7), end: Date().addingTimeInterval(86400 * 30),
                                refreshedAt: Date().addingTimeInterval(-86400 * 3))
        let service = makeService([
            Provider(account: CalendarAccount(displayName: "W", serverURL: "", email: "", accountType: .owa), error: URLError(.notConnectedToInternet)),
            Provider(account: CalendarAccount(displayName: "L", serverURL: "", email: "", accountType: .eventKit)),
        ])
        service.setEventCoverageForTests(old)

        await service.performSyncForTests()

        XCTAssertEqual(service.eventCoverage, old)
        XCTAssertTrue(service.syncStatus.isOfflineCached)
    }
}
