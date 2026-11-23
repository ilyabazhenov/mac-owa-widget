import XCTest
@testable import OWAWidget

final class MeetingReplyOptionsTests: XCTestCase {
    private let account = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

    private func event(_ id: String, series: String? = nil, response: MeetingResponseType = .notResponded, account: UUID? = nil) -> CalendarEvent {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        return CalendarEvent(
            id: id, title: "Sync", startDate: start, endDate: start.addingTimeInterval(1800),
            location: nil, bodyPreview: nil, joinURL: nil, platform: .generic, isAllDay: false,
            organizer: "Org", accountID: account ?? self.account, responseType: response,
            changeKey: "ck", seriesID: series
        )
    }

    func testOnlyAPlainAnswerKeepsTheEWSRequest() {
        XCTAssertFalse(MeetingReplyOptions().needsCalendarEventRequest)
        XCTAssertFalse(MeetingReplyOptions(comment: "   \n").needsCalendarEventRequest, "a blank comment is no comment")
        XCTAssertTrue(MeetingReplyOptions(series: true).needsCalendarEventRequest)
        XCTAssertTrue(MeetingReplyOptions(notifyOrganizer: false).needsCalendarEventRequest)
        XCTAssertTrue(MeetingReplyOptions(comment: "Late").needsCalendarEventRequest)
    }

    func testCommentIsTrimmedLimitedAndDroppedWhenNobodyIsTold() {
        XCTAssertEqual(MeetingReplyOptions(comment: "  Late  ").effectiveComment, "Late")
        XCTAssertEqual(MeetingReplyOptions(notifyOrganizer: false, comment: "Late").effectiveComment, "")
        let long = String(repeating: "a", count: MeetingReplyOptions.commentLimit + 50)
        XCTAssertEqual(MeetingReplyOptions(comment: long).effectiveComment.count, MeetingReplyOptions.commentLimit)
    }

    func testSummaryNamesTheScopeAndWhetherTheOrganizerWasTold() {
        let en = MeetingInvitationLocalization.english
        XCTAssertEqual(en.summary(action: .accept, series: false, notify: true), "Accepted · response sent")
        XCTAssertEqual(en.summary(action: .decline, series: true, notify: false), "Declined for the whole series · organizer not notified")
        let tr: (String) -> String = { $0 }
        XCTAssertEqual(
            MeetingReplySummary.text(action: .tentative, options: MeetingReplyOptions(comment: "Late"), tr: tr),
            "meeting.reply.done.tentative · meeting.reply.done.sentWithComment"
        )
    }

    func testCardStartsWithTheSeriesOnlyWhileNoOccurrenceIsAnswered() {
        let fresh = [event("a", series: "s"), event("b", series: "s")]
        XCTAssertTrue(MeetingReplyScope.defaultsToSeries(fresh[0], in: fresh))

        let answered = [event("a", series: "s"), event("b", series: "s", response: .accepted)]
        XCTAssertFalse(MeetingReplyScope.defaultsToSeries(answered[0], in: answered))

        let single = event("x")
        XCTAssertFalse(MeetingReplyScope.defaultsToSeries(single, in: [single]))
    }

    func testFoldedRowIsOneSeriesOnlyWithOneSeriesID() {
        XCTAssertTrue(MeetingReplyScope.isSingleSeries([event("a", series: "s"), event("b", series: "s")]))
        XCTAssertFalse(MeetingReplyScope.isSingleSeries([event("a", series: "s")]), "one meeting is answered on its own")
        XCTAssertFalse(MeetingReplyScope.isSingleSeries([event("a", series: "s"), event("b", series: "t")]))
        XCTAssertFalse(MeetingReplyScope.isSingleSeries([event("a"), event("b")]), "same subject, unrelated one-offs")
    }

    @MainActor
    func testFoldedSeriesRowCanBeAnsweredInThePanel() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let events = [event("a", series: "s"), event("b", series: "s")]
        let alert = MeetingInvitationAlert(
            change: .invited, eventIDs: ["a", "b"], accountID: account, title: "Sync", organizer: "Org",
            startDate: events[0].startDate, endDate: events[0].endDate, isAllDay: false
        )
        let byID = Dictionary(uniqueKeysWithValues: events.map { ($0.id, $0) })
        XCTAssertTrue(MeetingInvitationAlertController.canRespond(alert, byID: byID, now: now))

        let cancelled = MeetingInvitationAlert(
            change: .cancelled, eventIDs: ["a"], accountID: account, title: "Sync", organizer: "Org",
            startDate: events[0].startDate, endDate: events[0].endDate, isAllDay: false
        )
        XCTAssertFalse(MeetingInvitationAlertController.canRespond(cancelled, byID: byID, now: now))
    }
}

/// `CalendarService.reply`: which Exchange request each choice sends.
@MainActor
final class CalendarServiceReplyTests: XCTestCase {
    private actor RecordingProvider: CalendarProvider {
        struct Call: Equatable {
            let kind: String
            let eventID: String
            let series: Bool
            let notes: String
            let send: Bool
        }

        nonisolated let account: CalendarAccount
        private(set) var calls: [Call] = []
        /// What the server holds, answers included: a series answer starts a sync in the
        /// background, and it must find the meetings (with their new answers) rather than none.
        private var stored: [CalendarEvent]

        init(account: CalendarAccount, events: [CalendarEvent] = []) {
            self.account = account
            self.stored = events
        }

        struct Refused: Error {}

        /// A held fetch answers with the calendar as it was when the fetch began: what a
        /// `GetCalendarView` already on its way brings back when an answer lands meanwhile.
        private var holdingFetches = false
        /// Keyed by the fetch's number, from 1.
        private var heldFetches: [Int: CheckedContinuation<Void, Never>] = [:]
        private(set) var fetchesStarted = 0
        /// A held answer is on its way: Exchange has not taken it yet.
        private var holdingResponses = false
        private var heldResponses: [CheckedContinuation<Void, Never>] = []
        private(set) var responsesStarted = 0
        private var refusing = false

        func holdFetches() { holdingFetches = true }
        func releaseFetches() {
            holdingFetches = false
            heldFetches.values.forEach { $0.resume() }
            heldFetches = [:]
        }
        /// Lets one held fetch answer; the others stay held.
        func releaseFetch(_ number: Int) {
            heldFetches.removeValue(forKey: number)?.resume()
        }
        func holdResponses() { holdingResponses = true }
        func releaseResponses() {
            holdingResponses = false
            heldResponses.forEach { $0.resume() }
            heldResponses = []
        }
        func refuseResponses() { refusing = true }
        /// The answer changed elsewhere (Outlook, the phone).
        func setServerResponse(_ type: MeetingResponseType, for eventID: String) {
            stored = stored.map { $0.id == eventID ? $0.withResponseType(type) : $0 }
        }

        func fetchEvents(from start: Date, to end: Date) async throws -> [CalendarEvent] {
            let snapshot = stored
            fetchesStarted += 1
            let number = fetchesStarted
            if holdingFetches { await withCheckedContinuation { heldFetches[number] = $0 } }
            return snapshot
        }
        func validateCredentials() async throws {}
        func respondToMeeting(_ event: CalendarEvent, action: MeetingResponseAction) async throws {
            calls.append(Call(kind: "ews", eventID: event.id, series: false, notes: "", send: true))
            try await arrive()
            record(action, for: event, series: false)
        }
        func respondToCalendarEvent(_ event: CalendarEvent, action: MeetingResponseAction, series: Bool, notes: String, sendResponse: Bool) async throws {
            calls.append(Call(kind: "owa", eventID: event.id, series: series, notes: notes, send: sendResponse))
            try await arrive()
            record(action, for: event, series: series)
        }

        private func arrive() async throws {
            responsesStarted += 1
            if holdingResponses { await withCheckedContinuation { heldResponses.append($0) } }
            if refusing { throw Refused() }
        }

        private func record(_ action: MeetingResponseAction, for event: CalendarEvent, series: Bool) {
            let type: MeetingResponseType = switch action {
            case .accept: .accepted
            case .tentative: .tentative
            case .decline: .declined
            }
            stored = stored.map { item in
                let hit = series ? (item.seriesID != nil && item.seriesID == event.seriesID) : item.id == event.id
                return hit ? item.withResponseType(type) : item
            }
        }
    }

    private final class NullCache: EventCacheStoring {
        func load() -> EventCacheSnapshot? { nil }
        func save(events: [CalendarEvent], rangeStart: Date, rangeEnd: Date) {}
        func clear() {}
    }

    private final class NullPresenter: MeetingInvitationAlertPresenting {
        func present(_ alerts: [MeetingInvitationAlert], events: [CalendarEvent], localization: MeetingInvitationLocalization, sound: MeetingReminderSound) {}
        func reconcile(with events: [CalendarEvent]) {}
        func dismissAll() {}
    }

    private let account = CalendarAccount(displayName: "Exchange", serverURL: "", email: "", accountType: .owa)

    private func event(_ id: String, series: String? = nil) -> CalendarEvent {
        let start = Date().addingTimeInterval(86_400)
        return CalendarEvent(
            id: id, title: "Sync", startDate: start, endDate: start.addingTimeInterval(1800),
            location: nil, bodyPreview: nil, joinURL: nil, platform: .generic, isAllDay: false,
            organizer: "Org", accountID: account.id, changeKey: "ck", seriesID: series
        )
    }

    /// Syncs in these tests must not touch the real tracker's store.
    private final class NullTracker: MeetingInvitationTracking {
        func process(events: [CalendarEvent], refreshedAccountIDs: Set<UUID>, windowEnd: Date, now: Date) -> [MeetingInvitationAlert] { [] }
        var unhandledEventIDs: Set<String> { [] }
        func refreshUnhandled(events: [CalendarEvent], now: Date) {}
        func dismiss(eventIDs: [String]) {}
        func reset() {}
    }

    private func makeService(_ provider: RecordingProvider, events: [CalendarEvent]) -> CalendarService {
        let service = CalendarService(
            providers: [provider],
            eventCacheStore: NullCache(),
            notificationService: SilentNotificationService(),
            customMeetingReminders: SilentMeetingReminderController(),
            invitationTracker: NullTracker(),
            invitationAlerts: NullPresenter(),
            loadPersistedAccounts: false,
            startBackgroundTasks: false
        )
        service.replaceEventsForTests(events)
        return service
    }

    func testEachChoiceGoesThroughTheRightRequest() async throws {
        let one = event("a", series: "s")
        let provider = RecordingProvider(account: account, events: [one])
        let service = makeService(provider, events: [one])

        try await service.reply(to: one, action: .accept, options: MeetingReplyOptions())
        try await service.reply(to: one, action: .decline, options: MeetingReplyOptions(notifyOrganizer: false, comment: "Late"))
        // The series answer goes last: it starts a sync in the background, which may land in
        // `events` at any later suspension point. Read the answer before there is one.
        try await service.reply(to: one, action: .accept, options: MeetingReplyOptions(series: true, comment: " Late "))
        let shown = service.events.first?.responseType

        let calls = await provider.calls
        XCTAssertEqual(calls, [
            .init(kind: "ews", eventID: "a", series: false, notes: "", send: true),
            .init(kind: "owa", eventID: "a", series: false, notes: "", send: false),
            .init(kind: "owa", eventID: "a", series: true, notes: "Late", send: true),
        ])
        XCTAssertEqual(shown, .accepted)
    }

    func testFoldedSeriesIsOneSeriesAnswerAndUnrelatedMeetingsAreAnsweredInTurn() async throws {
        let series = [event("a", series: "s"), event("b", series: "s")]
        let oneOffs = [event("x"), event("y")]
        let provider = RecordingProvider(account: account, events: series + oneOffs)
        let service = makeService(provider, events: series + oneOffs)

        let seriesAnswer = try await service.reply(toInvitation: series, action: .accept, notifyOrganizer: false)
        // Read before the next suspension point: the series answer starts a sync in the background.
        let shown = service.events.filter { $0.seriesID == "s" }.map(\.responseType)
        let oneByOne = try await service.reply(toInvitation: oneOffs, action: .tentative, notifyOrganizer: true)
        // The panel's line says "for the whole series" only for a series answer.
        XCTAssertTrue(seriesAnswer)
        XCTAssertFalse(oneByOne)

        let calls = await provider.calls
        XCTAssertEqual(calls, [
            .init(kind: "owa", eventID: "a", series: true, notes: "", send: false),
            .init(kind: "ews", eventID: "x", series: false, notes: "", send: true),
            .init(kind: "ews", eventID: "y", series: false, notes: "", send: true),
        ])
        XCTAssertEqual(shown, [.accepted, .accepted])
    }

    // MARK: - An answer and a sync at the same time

    private func responses(_ service: CalendarService) -> [String: MeetingResponseType] {
        Dictionary(uniqueKeysWithValues: service.events.map { ($0.id, $0.responseType) })
    }

    /// Polls an actor's state: the sync and the answer run in tasks of their own.
    private func waitUntil(_ condition: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while await !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("timed out", file: file, line: line) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// A sync whose fetch left before the answer brings the meeting back unanswered: the answer
    /// stays on screen. The sync after it has the final word, an answer changed elsewhere included.
    func testAnswerGivenDuringASyncOutlivesItsEarlyFetch() async throws {
        let meeting = event("m")
        let provider = RecordingProvider(account: account, events: [meeting])
        let service = makeService(provider, events: [meeting])

        await provider.holdFetches()
        let sync = Task { await service.performSyncForTests() }
        try await waitUntil { await provider.fetchesStarted == 1 }
        try await service.reply(to: meeting, action: .accept, options: MeetingReplyOptions())
        await provider.releaseFetches()
        await sync.value
        XCTAssertEqual(responses(service), ["m": .accepted])

        await provider.setServerResponse(.declined, for: "m")
        await service.performSyncForTests()
        XCTAssertEqual(responses(service), ["m": .declined], "started after Exchange took the answer: Exchange decides")
    }

    /// Syncs overlap (the scheduler does not wait for a running one) and the newer one ends
    /// first: it must not forget the answer while the older one, which fetched before the
    /// answer, can still write the meeting back unanswered.
    func testNewerSyncEndingFirstDoesNotLetTheOlderOneUndoTheAnswer() async throws {
        let meeting = event("m")
        let provider = RecordingProvider(account: account, events: [meeting])
        let service = makeService(provider, events: [meeting])

        await provider.holdFetches()
        let older = Task { await service.performSyncForTests() }
        try await waitUntil { await provider.fetchesStarted == 1 }
        try await service.reply(to: meeting, action: .accept, options: MeetingReplyOptions())
        let newer = Task { await service.performSyncForTests() }
        try await waitUntil { await provider.fetchesStarted == 2 }

        await provider.releaseFetch(2)
        await newer.value
        XCTAssertEqual(responses(service), ["m": .accepted])
        await provider.releaseFetch(1)
        await older.value
        XCTAssertEqual(responses(service), ["m": .accepted], "the older sync fetched before the answer")

        await provider.releaseFetches()
        await provider.setServerResponse(.declined, for: "m")
        await service.performSyncForTests()
        XCTAssertEqual(responses(service), ["m": .declined], "no older sync left: Exchange decides")
    }

    /// The answer is still on its way when a sync ends: the sync shows it, and once Exchange
    /// has taken it the next sync decides again.
    func testAnswerOnItsWayIsKeptBySyncsUntilExchangeTakesIt() async throws {
        let meeting = event("m")
        let provider = RecordingProvider(account: account, events: [meeting])
        let service = makeService(provider, events: [meeting])

        await provider.holdResponses()
        let reply = Task { try await service.reply(to: meeting, action: .tentative, options: MeetingReplyOptions()) }
        try await waitUntil { await provider.responsesStarted == 1 }
        await service.performSyncForTests()
        XCTAssertEqual(responses(service), ["m": .tentative], "Exchange has not taken the answer yet")

        await provider.releaseResponses()
        try await reply.value
        // Exchange took it while no sync ran: the next sync is the first to see it.
        await service.performSyncForTests()
        XCTAssertEqual(responses(service), ["m": .tentative])
        await provider.setServerResponse(.accepted, for: "m")
        await service.performSyncForTests()
        XCTAssertEqual(responses(service), ["m": .accepted])
    }

    /// Exchange refused the answer while a sync was on its way: the sync shows the meeting as
    /// Exchange has it, not the refused answer.
    func testRefusedAnswerDuringASyncIsNotKept() async throws {
        let meeting = event("m")
        let provider = RecordingProvider(account: account, events: [meeting])
        let service = makeService(provider, events: [meeting])

        await provider.holdFetches()
        await provider.refuseResponses()
        let sync = Task { await service.performSyncForTests() }
        try await waitUntil { await provider.fetchesStarted == 1 }
        do {
            try await service.reply(to: meeting, action: .decline, options: MeetingReplyOptions(comment: "Late"))
            XCTFail("Exchange refused the answer")
        } catch {}
        await provider.releaseFetches()
        await sync.value
        XCTAssertEqual(responses(service), ["m": .notResponded])
    }

    /// A series answer while a sync is on its way: its own sync is turned away (one is running),
    /// and the running one must not bring the occurrences back unanswered.
    func testSeriesAnswerDuringASyncKeepsEveryOccurrence() async throws {
        let series = [event("a", series: "s"), event("b", series: "s")]
        let other = event("x")
        let provider = RecordingProvider(account: account, events: series + [other])
        let service = makeService(provider, events: series + [other])

        await provider.holdFetches()
        let sync = Task { await service.performSyncForTests() }
        try await waitUntil { await provider.fetchesStarted == 1 }
        try await service.reply(toInvitation: series, action: .accept, notifyOrganizer: true)
        await provider.releaseFetches()
        await sync.value
        XCTAssertEqual(responses(service), ["a": .accepted, "b": .accepted, "x": .notResponded])
        let fetches = await provider.fetchesStarted
        XCTAssertEqual(fetches, 1, "the series answer's own sync was turned away while one ran")
    }

    func testNotifyingTheOrganizerIsOnUntilTheUserTurnsItOff() {
        let key = "invitationNotifyOrganizerByDefault"
        let saved = UserDefaults.standard.object(forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
        let service = makeService(RecordingProvider(account: account), events: [])
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertTrue(service.invitationNotifyOrganizerByDefault)
        service.invitationNotifyOrganizerByDefault = false
        XCTAssertFalse(service.invitationNotifyOrganizerByDefault)
    }
}
