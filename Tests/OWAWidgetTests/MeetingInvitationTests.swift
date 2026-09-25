import XCTest
@testable import OWAWidget

final class MeetingInvitationPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let exchange = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let other = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

    private func event(
        _ id: String,
        title: String? = nil,
        hoursFromNow: Double = 24,
        account: UUID? = nil,
        organizer: String? = "Ivan Petrov",
        response: MeetingResponseType = .notResponded,
        isOrganizer: Bool = false,
        isCancelled: Bool = false,
        changeKey: String? = "ck"
    ) -> CalendarEvent {
        let start = now.addingTimeInterval(hoursFromNow * 3600)
        return CalendarEvent(
            id: id,
            title: title ?? id,
            startDate: start,
            endDate: start.addingTimeInterval(1800),
            location: nil,
            bodyPreview: nil,
            joinURL: nil,
            platform: .generic,
            isAllDay: false,
            organizer: organizer,
            accountID: account ?? exchange,
            isCancelled: isCancelled,
            isOrganizer: isOrganizer,
            responseType: response,
            changeKey: changeKey
        )
    }

    private func baselined(_ events: [CalendarEvent]) -> MeetingInvitationTrackerState {
        MeetingInvitationPolicy.diff(
            previous: .empty,
            events: events,
            refreshedAccountIDs: [exchange],
            now: now
        ).next
    }

    // MARK: - What counts as an invitation

    func testAwaitingResponseRequiresExchangeMeetingOrganisedBySomeoneElse() {
        XCTAssertTrue(MeetingInvitationPolicy.isAwaitingResponse(event("a"), now: now))
        XCTAssertFalse(MeetingInvitationPolicy.isAwaitingResponse(event("b", response: .accepted), now: now))
        XCTAssertFalse(MeetingInvitationPolicy.isAwaitingResponse(event("c", isOrganizer: true), now: now))
        XCTAssertFalse(MeetingInvitationPolicy.isAwaitingResponse(event("d", response: .organizer), now: now))
        XCTAssertFalse(MeetingInvitationPolicy.isAwaitingResponse(event("e", isCancelled: true), now: now))
        XCTAssertFalse(MeetingInvitationPolicy.isAwaitingResponse(event("f", hoursFromNow: -2), now: now))
    }

    /// Holiday and subscribed calendars synced by macOS report "not responded" for every entry.
    /// Without an Exchange change key there is nothing to answer, so nothing to announce.
    func testReadOnlyCalendarEntriesAreNeverTracked() {
        XCTAssertFalse(MeetingInvitationPolicy.isAwaitingResponse(event("holiday", changeKey: nil), now: now))
    }

    // MARK: - Diff

    func testFirstSyncOfAnAccountIsSilent() {
        let result = MeetingInvitationPolicy.diff(
            previous: .empty,
            events: [event("a"), event("b")],
            refreshedAccountIDs: [exchange],
            now: now
        )

        XCTAssertTrue(result.alerts.isEmpty)
        XCTAssertEqual(result.next.baselinedAccountIDs, [exchange])
        XCTAssertEqual(Set(result.next.fingerprints.keys), ["a", "b"])
    }

    func testNewUnansweredMeetingRaisesInvitation() throws {
        let previous = baselined([event("a")])

        let result = MeetingInvitationPolicy.diff(
            previous: previous,
            events: [event("a"), event("new", title: "Planning")],
            refreshedAccountIDs: [exchange],
            now: now
        )

        let alert = try XCTUnwrap(result.alerts.first)
        XCTAssertEqual(result.alerts.count, 1)
        XCTAssertEqual(alert.change, .invited)
        XCTAssertEqual(alert.eventIDs, ["new"])
        XCTAssertEqual(alert.title, "Planning")
    }

    func testNewMeetingAlreadyAnsweredOrOwnIsNotAnnounced() {
        let previous = baselined([])

        let result = MeetingInvitationPolicy.diff(
            previous: previous,
            events: [event("accepted", response: .accepted), event("mine", isOrganizer: true)],
            refreshedAccountIDs: [exchange],
            now: now
        )

        XCTAssertTrue(result.alerts.isEmpty)
    }

    /// A freshly added account brings its whole calendar at once; none of it is news.
    func testNewlyAddedAccountIsBaselinedSilently() {
        let previous = baselined([event("a")])

        let result = MeetingInvitationPolicy.diff(
            previous: previous,
            events: [event("a"), event("x", account: other)],
            refreshedAccountIDs: [exchange, other],
            now: now
        )

        XCTAssertTrue(result.alerts.isEmpty)
        XCTAssertEqual(result.next.baselinedAccountIDs, [exchange, other])
    }

    /// Meetings kept from an account that failed to sync are compared against nothing new: they
    /// must not be reported just because they are in the list.
    func testAccountNotRefreshedRaisesNothing() {
        let previous = MeetingInvitationTrackerState(baselinedAccountIDs: [exchange, other], fingerprints: [:])

        let result = MeetingInvitationPolicy.diff(
            previous: previous,
            events: [event("x", account: other)],
            refreshedAccountIDs: [exchange],
            now: now
        )

        XCTAssertTrue(result.alerts.isEmpty)
        XCTAssertNotNil(result.next.fingerprints["x"])
    }

    func testMovedMeetingRaisesRescheduleWithPreviousTime() throws {
        let original = event("a", hoursFromNow: 24, response: .accepted)
        let previous = baselined([original])
        let moved = event("a", hoursFromNow: 26, response: .accepted)

        let result = MeetingInvitationPolicy.diff(
            previous: previous,
            events: [moved],
            refreshedAccountIDs: [exchange],
            now: now
        )

        let alert = try XCTUnwrap(result.alerts.first)
        XCTAssertEqual(alert.change, .rescheduled(previousStart: original.startDate, previousEnd: original.endDate))
        XCTAssertEqual(alert.startDate, moved.startDate)
    }

    func testDeclinedMeetingMovingIsIgnored() {
        let previous = baselined([event("a", response: .declined)])

        let result = MeetingInvitationPolicy.diff(
            previous: previous,
            events: [event("a", hoursFromNow: 30, response: .declined)],
            refreshedAccountIDs: [exchange],
            now: now
        )

        XCTAssertTrue(result.alerts.isEmpty)
    }

    func testCancellationIsReportedOnce() {
        let previous = baselined([event("a", response: .accepted)])
        let cancelled = event("a", response: .accepted, isCancelled: true)

        let first = MeetingInvitationPolicy.diff(
            previous: previous,
            events: [cancelled],
            refreshedAccountIDs: [exchange],
            now: now
        )
        let second = MeetingInvitationPolicy.diff(
            previous: first.next,
            events: [cancelled],
            refreshedAccountIDs: [exchange],
            now: now
        )

        XCTAssertEqual(first.alerts.map(\.change), [.cancelled])
        XCTAssertTrue(second.alerts.isEmpty)
    }

    /// Exchange's own "Canceled:" subject prefix counts too — older servers set only that.
    func testCancellationBySubjectPrefixIsReported() {
        let previous = baselined([event("a", title: "Sync", response: .accepted)])

        let result = MeetingInvitationPolicy.diff(
            previous: previous,
            events: [event("a", title: "Отменено: Sync", response: .accepted)],
            refreshedAccountIDs: [exchange],
            now: now
        )

        XCTAssertEqual(result.alerts.map(\.change), [.cancelled])
    }

    /// An invitation the user never accepted was never in their plans: its cancellation is noise.
    func testCancellationOfUnansweredInvitationIsSilentAndLeavesBadge() {
        let previous = baselined([])
        let invited = MeetingInvitationPolicy.diff(
            previous: previous, events: [event("a", title: "Test")], refreshedAccountIDs: [exchange], now: now
        )
        let cancelled = MeetingInvitationPolicy.diff(
            previous: invited.next,
            events: [event("a", title: "Отменено: Test", isCancelled: true)],
            refreshedAccountIDs: [exchange],
            now: now
        )

        XCTAssertEqual(invited.next.unhandledEventIDs, ["a"])
        XCTAssertTrue(cancelled.alerts.isEmpty)
        XCTAssertTrue(cancelled.next.unhandledEventIDs.isEmpty)
    }

    /// Exchange may reset the answer on the cancelled item; the answer recorded at the previous
    /// sync is what counts.
    func testCancellationOfAcceptedMeetingIsReportedEvenIfAnswerWasReset() {
        let previous = baselined([event("a", response: .tentative)])

        let result = MeetingInvitationPolicy.diff(
            previous: previous,
            events: [event("a", isCancelled: true)],
            refreshedAccountIDs: [exchange],
            now: now
        )

        XCTAssertEqual(result.alerts.map(\.change), [.cancelled])
    }

    func testCancelledTitleLosesExchangePrefix() {
        let previous = baselined([event("a", title: "Sync", response: .accepted)])

        let result = MeetingInvitationPolicy.diff(
            previous: previous,
            events: [event("a", title: "Отменено: Sync", response: .accepted)],
            refreshedAccountIDs: [exchange],
            now: now
        )

        XCTAssertEqual(result.alerts.first?.title, "Sync")
        XCTAssertEqual(MeetingInvitationPolicy.displayTitle(of: event("b", title: "Canceled: Review")), "Review")
        XCTAssertEqual(MeetingInvitationPolicy.displayTitle(of: event("c", title: "Отменено:")), "Отменено:")
    }

    func testInvitationsComeBeforeUpdatesRegardlessOfTime() {
        let previous = baselined([event("moved", hoursFromNow: 2, response: .accepted), event("gone", hoursFromNow: 1, response: .accepted)])

        let result = MeetingInvitationPolicy.diff(
            previous: previous,
            events: [
                event("gone", hoursFromNow: 1, response: .accepted, isCancelled: true),
                event("moved", hoursFromNow: 3, response: .accepted),
                event("new", hoursFromNow: 48),
            ],
            refreshedAccountIDs: [exchange],
            now: now
        )

        XCTAssertEqual(result.alerts.map(\.representativeEventID), ["new", "moved", "gone"])
    }

    func testFingerprintWrittenBeforeCommitmentFieldStillDecodes() throws {
        let legacy = #"{"startDate":0,"endDate":1,"isCancelled":false}"#.data(using: .utf8)!
        let fingerprint = try JSONDecoder().decode(MeetingInvitationFingerprint.self, from: legacy)
        XCTAssertFalse(fingerprint.wasCommitted)
    }

    func testSameInvitationIsNotRepeatedOnNextSync() {
        let previous = baselined([])
        let invite = event("new")
        let first = MeetingInvitationPolicy.diff(previous: previous, events: [invite], refreshedAccountIDs: [exchange], now: now)
        let second = MeetingInvitationPolicy.diff(previous: first.next, events: [invite], refreshedAccountIDs: [exchange], now: now)

        XCTAssertEqual(first.alerts.count, 1)
        XCTAssertTrue(second.alerts.isEmpty)
    }

    func testPastMeetingsAreDroppedFromState() {
        let result = MeetingInvitationPolicy.diff(
            previous: .empty,
            events: [event("past", hoursFromNow: -3), event("future")],
            refreshedAccountIDs: [exchange],
            now: now
        )

        XCTAssertEqual(Set(result.next.fingerprints.keys), ["future"])
    }

    // MARK: - Unhandled invitations (badge)

    func testAnnouncedInvitationJoinsBadgeAndLeavesOnceAnswered() {
        let previous = baselined([event("old")])
        let first = MeetingInvitationPolicy.diff(
            previous: previous,
            events: [event("old"), event("new")],
            refreshedAccountIDs: [exchange],
            now: now
        )
        let answered = MeetingInvitationPolicy.diff(
            previous: first.next,
            events: [event("old"), event("new", response: .accepted)],
            refreshedAccountIDs: [exchange],
            now: now
        )

        XCTAssertEqual(first.next.unhandledEventIDs, ["new"])
        XCTAssertTrue(answered.next.unhandledEventIDs.isEmpty)
    }

    func testCancelledAndAnsweredMovesDoNotJoinBadge() {
        let previous = baselined([event("a", response: .accepted), event("b", response: .accepted)])

        let result = MeetingInvitationPolicy.diff(
            previous: previous,
            events: [event("a", hoursFromNow: 30, response: .accepted), event("b", response: .accepted, isCancelled: true)],
            refreshedAccountIDs: [exchange],
            now: now
        )

        XCTAssertEqual(result.alerts.count, 2)
        XCTAssertTrue(result.next.unhandledEventIDs.isEmpty)
    }

    /// Exchange resets the answer when a meeting moves; that one needs an answer again.
    func testMovedMeetingAwaitingAnswerJoinsBadge() {
        let previous = baselined([event("a", response: .accepted)])

        let result = MeetingInvitationPolicy.diff(
            previous: previous,
            events: [event("a", hoursFromNow: 30)],
            refreshedAccountIDs: [exchange],
            now: now
        )

        XCTAssertEqual(result.next.unhandledEventIDs, ["a"])
    }

    func testStateWrittenBeforeBadgeExistedStillDecodes() throws {
        let legacy = #"{"baselinedAccountIDs":[],"fingerprints":{}}"#.data(using: .utf8)!
        let state = try JSONDecoder().decode(MeetingInvitationTrackerState.self, from: legacy)
        XCTAssertTrue(state.unhandledEventIDs.isEmpty)
    }

    func testMenuBarLabelCarriesInvitationCount() {
        XCTAssertEqual(MenuBarLabelView.composedLabel("18m", pendingInvitations: 0), "18m")
        XCTAssertEqual(MenuBarLabelView.composedLabel("18m", pendingInvitations: 2), "18m \u{2709}\u{FE0E}2")
        XCTAssertEqual(MenuBarLabelView.composedLabel(nil, pendingInvitations: 3), "\u{2709}\u{FE0E}3")
    }

    // MARK: - Series folding

    func testOccurrencesOfOneSeriesFoldIntoOneAlert() throws {
        let previous = baselined([])
        let occurrences = [
            event("w1", title: "Weekly", hoursFromNow: 24),
            event("w2", title: "Weekly", hoursFromNow: 24 * 8),
            event("w3", title: "Weekly", hoursFromNow: 24 * 15),
        ]

        let result = MeetingInvitationPolicy.diff(
            previous: previous,
            events: occurrences.reversed() + [event("solo", title: "Review", hoursFromNow: 48)],
            refreshedAccountIDs: [exchange],
            now: now
        )

        XCTAssertEqual(result.alerts.count, 2)
        let weekly = try XCTUnwrap(result.alerts.first { $0.title == "Weekly" })
        XCTAssertEqual(weekly.eventIDs, ["w1", "w2", "w3"])
        XCTAssertEqual(weekly.startDate, occurrences[0].startDate)
    }

    func testSameSubjectFromDifferentOrganisersDoesNotFold() {
        let groups = MeetingInvitationPolicy.pendingGroups(
            in: [event("a", title: "Sync", organizer: "Anna"), event("b", title: "Sync", organizer: "Boris")],
            now: now
        )

        XCTAssertEqual(groups.count, 2)
    }

    func testPendingGroupsSkipAnsweredMeetings() {
        let groups = MeetingInvitationPolicy.pendingGroups(
            in: [event("a"), event("b", response: .tentative), event("c", response: .declined)],
            now: now
        )

        XCTAssertEqual(groups.map(\.representative.id), ["a"])
    }

    // MARK: - Panel title

    func testPanelTitleDependsOnWhatIsShown() {
        let loc = MeetingInvitationLocalization.english
        let invite = MeetingInvitationAlert(
            change: .invited, eventIDs: ["a"], accountID: exchange, title: "A",
            organizer: nil, startDate: now, endDate: now, isAllDay: false
        )
        let cancelled = MeetingInvitationAlert(
            change: .cancelled, eventIDs: ["b"], accountID: exchange, title: "B",
            organizer: nil, startDate: now, endDate: now, isAllDay: false
        )

        XCTAssertEqual(loc.title(for: [invite]), "New invitation")
        XCTAssertEqual(loc.title(for: [invite, invite]), "New invitations · 2")
        XCTAssertEqual(loc.title(for: [invite, cancelled]), "Calendar changes")
    }
}

@MainActor
final class MeetingInvitationTrackerTests: XCTestCase {
    private var directory: URL!
    private var secureStore: SecureStore!
    private let account = UUID()

    override func setUp() {
        super.setUp()
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("invitation-tracker-tests-\(UUID().uuidString)", isDirectory: true)
        secureStore = SecureStore(directory: directory, keyProvider: InMemorySecureStoreKeyProvider())
    }

    override func tearDown() {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        super.tearDown()
    }

    private let start = Date().addingTimeInterval(86_400)

    private func invite(_ id: String) -> CalendarEvent {
        return CalendarEvent(
            id: id, title: id, startDate: start, endDate: start.addingTimeInterval(1800),
            location: nil, bodyPreview: nil, joinURL: nil, platform: .generic,
            isAllDay: false, organizer: "Org", accountID: account, changeKey: "ck"
        )
    }

    /// An invitation that arrives while the app is closed must still be reported after relaunch.
    func testStateSurvivesRelaunch() {
        let first = MeetingInvitationTracker(secureStore: secureStore)
        XCTAssertTrue(first.process(events: [invite("a")], refreshedAccountIDs: [account], now: Date()).isEmpty)

        let relaunched = MeetingInvitationTracker(secureStore: secureStore)
        let alerts = relaunched.process(events: [invite("a"), invite("b")], refreshedAccountIDs: [account], now: Date())

        XCTAssertEqual(alerts.map(\.eventIDs), [["b"]])
    }

    func testResetStartsAFreshSilentBaseline() {
        let tracker = MeetingInvitationTracker(secureStore: secureStore)
        _ = tracker.process(events: [invite("a")], refreshedAccountIDs: [account], now: Date())

        tracker.reset()
        let afterReset = tracker.process(events: [invite("a"), invite("b")], refreshedAccountIDs: [account], now: Date())

        XCTAssertTrue(afterReset.isEmpty)
    }
}

/// End to end through `CalendarService`: sync → tracker → panel.
@MainActor
final class CalendarServiceInvitationTests: XCTestCase {
    private actor MutableProvider: CalendarProvider {
        nonisolated let account: CalendarAccount
        private var events: [CalendarEvent] = []

        init(account: CalendarAccount) { self.account = account }

        func set(_ events: [CalendarEvent]) { self.events = events }
        func fetchEvents(from start: Date, to end: Date) async throws -> [CalendarEvent] { events }
        func validateCredentials() async throws {}
    }

    private final class InMemoryTracker: MeetingInvitationTracking {
        private var state = MeetingInvitationTrackerState.empty
        func process(events: [CalendarEvent], refreshedAccountIDs: Set<UUID>, now: Date) -> [MeetingInvitationAlert] {
            let result = MeetingInvitationPolicy.diff(previous: state, events: events, refreshedAccountIDs: refreshedAccountIDs, now: now)
            state = result.next
            return result.alerts
        }
        var unhandledEventIDs: Set<String> { state.unhandledEventIDs }
        func refreshUnhandled(events: [CalendarEvent], now: Date) {
            state.unhandledEventIDs = MeetingInvitationPolicy.stillUnhandled(state.unhandledEventIDs, in: events, now: now)
        }
        func dismiss(eventIDs: [String]) { state.unhandledEventIDs.subtract(eventIDs) }
        func reset() { state = .empty }
    }

    private final class RecordingPresenter: MeetingInvitationAlertPresenting {
        private(set) var presented: [[MeetingInvitationAlert]] = []
        private(set) var dismissCount = 0
        func present(_ alerts: [MeetingInvitationAlert], events: [CalendarEvent], localization: MeetingInvitationLocalization, sound: MeetingReminderSound) {
            presented.append(alerts)
        }
        func reconcile(with events: [CalendarEvent]) {}
        func dismissAll() { dismissCount += 1 }
    }

    private final class NullCache: EventCacheStoring {
        func load() -> EventCacheSnapshot? { nil }
        func save(events: [CalendarEvent], rangeStart: Date, rangeEnd: Date) {}
        func clear() {}
    }

    private let enabledKey = "invitationAlertsEnabled"
    private let badgeKey = "invitationMenuBarBadgeEnabled"
    private var savedFlags: [String: Any] = [:]

    override func setUp() {
        super.setUp()
        for key in [enabledKey, badgeKey] {
            savedFlags[key] = UserDefaults.standard.object(forKey: key)
        }
    }

    override func tearDown() {
        for key in [enabledKey, badgeKey] {
            if let value = savedFlags[key] {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        super.tearDown()
    }

    private let start = Date().addingTimeInterval(86_400)

    private func invite(_ id: String, accountID: UUID) -> CalendarEvent {
        return CalendarEvent(
            id: id, title: id, startDate: start, endDate: start.addingTimeInterval(1800),
            location: nil, bodyPreview: nil, joinURL: nil, platform: .generic,
            isAllDay: false, organizer: "Org", accountID: accountID, changeKey: "ck"
        )
    }

    private func makeService(provider: MutableProvider, presenter: RecordingPresenter) -> CalendarService {
        CalendarService(
            providers: [provider],
            eventCacheStore: NullCache(),
            notificationService: SilentNotificationService(),
            customMeetingReminders: SilentMeetingReminderController(),
            invitationTracker: InMemoryTracker(),
            invitationAlerts: presenter,
            loadPersistedAccounts: false,
            startBackgroundTasks: false
        )
    }

    func testNewInvitationAfterBaselineReachesThePanel() async {
        UserDefaults.standard.set(true, forKey: enabledKey)
        let account = CalendarAccount(displayName: "Exchange", serverURL: "", email: "", accountType: .owa)
        let provider = MutableProvider(account: account)
        let presenter = RecordingPresenter()
        let service = makeService(provider: provider, presenter: presenter)

        await provider.set([invite("a", accountID: account.id)])
        await service.performSyncForTests()
        await provider.set([invite("a", accountID: account.id), invite("b", accountID: account.id)])
        await service.performSyncForTests()

        XCTAssertEqual(presenter.presented.map { $0.map(\.eventIDs) }, [[["b"]]])
        // Only the new invitation counts: "a" was already on the calendar when tracking started.
        XCTAssertEqual(service.pendingInvitationGroups.map(\.representative.id), ["b"])

        service.dismissInvitations(eventIDs: ["b"])
        XCTAssertTrue(service.pendingInvitationGroups.isEmpty)
    }

    func testMenuBarBadgeCanBeTurnedOffWithoutLosingTheList() async {
        UserDefaults.standard.set(true, forKey: enabledKey)
        UserDefaults.standard.set(false, forKey: badgeKey)
        let account = CalendarAccount(displayName: "Exchange", serverURL: "", email: "", accountType: .owa)
        let provider = MutableProvider(account: account)
        let presenter = RecordingPresenter()
        let service = makeService(provider: provider, presenter: presenter)

        await provider.set([])
        await service.performSyncForTests()
        await provider.set([invite("b", accountID: account.id)])
        await service.performSyncForTests()

        XCTAssertEqual(presenter.presented.count, 1)
        XCTAssertEqual(service.pendingInvitationGroups.count, 1)
        XCTAssertEqual(service.menuBarInvitationCount, 0)
    }

    func testDisabledFeatureStaysSilentAndHidesBadge() async {
        UserDefaults.standard.set(false, forKey: enabledKey)
        let account = CalendarAccount(displayName: "Exchange", serverURL: "", email: "", accountType: .owa)
        let provider = MutableProvider(account: account)
        let presenter = RecordingPresenter()
        let service = makeService(provider: provider, presenter: presenter)

        await provider.set([invite("a", accountID: account.id)])
        await service.performSyncForTests()
        await provider.set([invite("a", accountID: account.id), invite("b", accountID: account.id)])
        await service.performSyncForTests()

        XCTAssertTrue(presenter.presented.isEmpty)
        XCTAssertTrue(service.pendingInvitationGroups.isEmpty)
    }

    func testTurningFeatureOffClosesThePanel() {
        UserDefaults.standard.set(false, forKey: enabledKey)
        let account = CalendarAccount(displayName: "Exchange", serverURL: "", email: "", accountType: .owa)
        let presenter = RecordingPresenter()
        let service = makeService(provider: MutableProvider(account: account), presenter: presenter)

        service.applySavedPreferences()

        XCTAssertEqual(presenter.dismissCount, 1)
    }
}
