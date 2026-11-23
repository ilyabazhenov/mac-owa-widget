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

        func fetchEvents(from start: Date, to end: Date) async throws -> [CalendarEvent] { stored }
        func validateCredentials() async throws {}
        func respondToMeeting(_ event: CalendarEvent, action: MeetingResponseAction) async throws {
            calls.append(Call(kind: "ews", eventID: event.id, series: false, notes: "", send: true))
            record(action, for: event, series: false)
        }
        func respondToCalendarEvent(_ event: CalendarEvent, action: MeetingResponseAction, series: Bool, notes: String, sendResponse: Bool) async throws {
            calls.append(Call(kind: "owa", eventID: event.id, series: series, notes: notes, send: sendResponse))
            record(action, for: event, series: series)
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

    private func makeService(_ provider: RecordingProvider, events: [CalendarEvent]) -> CalendarService {
        let service = CalendarService(
            providers: [provider],
            eventCacheStore: NullCache(),
            notificationService: SilentNotificationService(),
            customMeetingReminders: SilentMeetingReminderController(),
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
