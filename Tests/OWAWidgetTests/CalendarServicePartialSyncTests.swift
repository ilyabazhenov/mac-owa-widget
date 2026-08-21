import XCTest
@testable import OWAWidget

/// How one sync pass combines fresh results with what was already on screen.
///
/// This is where a second real provider changed the rules: fetching no longer fails fast, so the
/// service has to decide per account whether to keep, replace, or drop what it holds. Getting that
/// wrong is invisible in provider-level tests — both regressions below survived a green suite.
@MainActor
final class CalendarServicePartialSyncTests: XCTestCase {

    private actor StubProvider: CalendarProvider {
        nonisolated let account: CalendarAccount
        private let events: [CalendarEvent]
        private let error: Error?
        private(set) var fetchCallCount = 0

        init(account: CalendarAccount, events: [CalendarEvent] = [], error: Error? = nil) {
            self.account = account
            self.events = events
            self.error = error
        }

        func fetchEvents(from start: Date, to end: Date) async throws -> [CalendarEvent] {
            fetchCallCount += 1
            if let error { throw error }
            return events
        }

        func validateCredentials() async throws {}
    }

    private final class RecordingEventCacheStore: EventCacheStoring {
        private(set) var savedEvents: [CalendarEvent] = []
        private(set) var saveCount = 0

        func load() -> EventCacheSnapshot? { nil }

        func save(events: [CalendarEvent], rangeStart: Date, rangeEnd: Date) {
            savedEvents = events
            saveCount += 1
        }

        func clear() {}
    }

    private func account(_ name: String, type: AccountType) -> CalendarAccount {
        CalendarAccount(displayName: name, serverURL: "", email: "", accountType: type)
    }

    private func event(id: String, accountID: UUID, minutesFromNow: Int = 30) -> CalendarEvent {
        let start = Date().addingTimeInterval(TimeInterval(minutesFromNow * 60))
        return CalendarEvent(
            id: id,
            title: id,
            startDate: start,
            endDate: start.addingTimeInterval(1800),
            location: nil,
            bodyPreview: nil,
            joinURL: nil,
            platform: .generic,
            isAllDay: false,
            organizer: nil,
            accountID: accountID
        )
    }

    private func makeService(
        providers: [any CalendarProvider],
        cache: any EventCacheStoring = RecordingEventCacheStore()
    ) -> CalendarService {
        CalendarService(
            providers: providers,
            eventCacheStore: cache,
            notificationService: SilentNotificationService(),
            customMeetingReminders: SilentMeetingReminderController(),
            loadPersistedAccounts: false,
            startBackgroundTasks: false
        )
    }

    // MARK: - Retention

    /// The account is gone, so its meetings must go with it. Keeping "everything not refreshed"
    /// would merge them back in on every sync and write them to the cache, so they would outlive
    /// the account that produced them — still on the timeline, still raising reminders.
    func testDropsEventsOfAnAccountThatNoLongerHasAProvider() async {
        let surviving = account("Exchange", type: .owa)
        let removed = account("Google", type: .eventKit)
        let provider = StubProvider(
            account: surviving,
            events: [event(id: "exchange-1", accountID: surviving.id)]
        )
        let service = makeService(providers: [provider])
        service.replaceEventsForTests([
            event(id: "exchange-1", accountID: surviving.id),
            event(id: "google-1", accountID: removed.id)
        ])

        await service.performSyncForTests()

        XCTAssertEqual(service.events.map(\.id), ["exchange-1"])
    }

    /// A provider that failed still has an account, so its events stay: one unreachable account
    /// must not blank out the calendar of a healthy one.
    func testKeepsEventsOfAProviderThatFailed() async {
        let healthy = account("Exchange", type: .owa)
        let broken = account("Google", type: .eventKit)
        let service = makeService(providers: [
            StubProvider(account: healthy, events: [event(id: "exchange-1", accountID: healthy.id)]),
            StubProvider(account: broken, error: EventKitStoreError.accessDenied)
        ])
        service.replaceEventsForTests([event(id: "google-1", accountID: broken.id)])

        await service.performSyncForTests()

        XCTAssertEqual(service.events.map(\.id).sorted(), ["exchange-1", "google-1"])
    }

    /// The failure still has to reach the status, or a broken account fails silently.
    func testPartialFailureIsStillReported() async {
        let healthy = account("Exchange", type: .owa)
        let broken = account("Google", type: .eventKit)
        let service = makeService(providers: [
            StubProvider(account: healthy, events: [event(id: "exchange-1", accountID: healthy.id)]),
            StubProvider(account: broken, error: EventKitStoreError.accessDenied)
        ])

        await service.performSyncForTests()

        XCTAssertTrue(service.syncStatus.isOfflineCached)
    }

    /// A failure that persists must not freeze the cache: what the healthy account returned has to
    /// survive a restart, or the next launch restores meetings from before the problem started.
    func testCachesFreshEventsEvenWhenAnotherProviderFailed() async {
        let healthy = account("Exchange", type: .owa)
        let broken = account("Google", type: .eventKit)
        let cache = RecordingEventCacheStore()
        let service = makeService(
            providers: [
                StubProvider(account: healthy, events: [event(id: "exchange-1", accountID: healthy.id)]),
                StubProvider(account: broken, error: EventKitStoreError.accessDenied)
            ],
            cache: cache
        )

        await service.performSyncForTests()

        XCTAssertEqual(cache.saveCount, 1)
        XCTAssertEqual(cache.savedEvents.map(\.id), ["exchange-1"])
    }

    // MARK: - Partial sync

    /// The system calendar fires its change notification on a schedule nobody here controls.
    /// Letting it pull the Exchange provider too would put a request to a corporate server behind
    /// every one of them, bypassing both the sync interval and the request gate.
    func testPartialSyncLeavesOtherProvidersAlone() async {
        let exchange = account("Exchange", type: .owa)
        let google = account("Google", type: .eventKit)
        let exchangeProvider = StubProvider(
            account: exchange,
            events: [event(id: "exchange-1", accountID: exchange.id)]
        )
        let googleProvider = StubProvider(
            account: google,
            events: [event(id: "google-2", accountID: google.id)]
        )
        let service = makeService(providers: [exchangeProvider, googleProvider])
        service.replaceEventsForTests([
            event(id: "exchange-1", accountID: exchange.id),
            event(id: "google-1", accountID: google.id)
        ])

        await service.performSyncForTests(limitedTo: [.eventKit])

        let exchangeCalls = await exchangeProvider.fetchCallCount
        let googleCalls = await googleProvider.fetchCallCount
        XCTAssertEqual(exchangeCalls, 0)
        XCTAssertEqual(googleCalls, 1)
        // Exchange keeps what it had; Google is replaced by what it just returned.
        XCTAssertEqual(service.events.map(\.id).sorted(), ["exchange-1", "google-2"])
    }

    func testPartialSyncDoesNothingWhenNoProviderMatches() async {
        let exchange = account("Exchange", type: .owa)
        let provider = StubProvider(account: exchange, events: [])
        let service = makeService(providers: [provider])

        await service.performSyncForTests(limitedTo: [.eventKit])

        let calls = await provider.fetchCallCount
        XCTAssertEqual(calls, 0)
    }

    /// A local calendar read succeeding says nothing about the Exchange password. Running the
    /// partial sync anyway would end on the success path, which resets `consecutiveAuthFailures`
    /// and clears the latch that exists to avoid an AD lockout.
    func testPartialSyncIsSkippedWhileSyncIsBlocked() async {
        let google = account("Google", type: .eventKit)
        let provider = StubProvider(account: google, events: [event(id: "google-1", accountID: google.id)])
        let service = makeService(providers: [provider])
        service.debugForceAuthBlock()

        await service.performSyncForTests(limitedTo: [.eventKit])

        let calls = await provider.fetchCallCount
        XCTAssertEqual(calls, 0)
        XCTAssertTrue(service.syncStatus.isAuthenticationRequired)
    }

    /// Reporting "synced just now" after refreshing only the local calendars hides an Exchange
    /// account that is still unreachable.
    func testPartialSyncKeepsAnUnresolvedFailureVisible() async {
        let google = account("Google", type: .eventKit)
        let service = makeService(providers: [
            StubProvider(account: google, events: [event(id: "google-1", accountID: google.id)])
        ])
        service.debugSimulateAuthFailure()
        XCTAssertTrue(service.syncStatus.isError)

        await service.performSyncForTests(limitedTo: [.eventKit])

        XCTAssertTrue(service.syncStatus.isError)
    }

    /// The breaker latches on the second consecutive auth failure. If a partial sync resets the
    /// counter, the second failure looks like the first and the app keeps feeding rejected
    /// credentials to Active Directory forever.
    func testPartialSyncDoesNotResetTheAuthBreaker() async {
        let google = account("Google", type: .eventKit)
        let service = makeService(providers: [
            StubProvider(account: google, events: [event(id: "google-1", accountID: google.id)])
        ])

        service.debugSimulateAuthFailure()
        XCTAssertFalse(service.syncStatus.isAuthenticationRequired, "first failure stays transient")

        await service.performSyncForTests(limitedTo: [.eventKit])
        service.debugSimulateAuthFailure()

        XCTAssertTrue(service.syncStatus.isAuthenticationRequired, "second failure must latch")
    }

    /// The request gate throttles manual refreshes to protect the Exchange server from bursts.
    /// A partial sync sends nothing to that server, so it must not spend the user's next refresh.
    func testPartialSyncDoesNotSwallowTheNextManualRefresh() async {
        let google = account("Google", type: .eventKit)
        let service = makeService(providers: [
            StubProvider(account: google, events: [event(id: "google-1", accountID: google.id)])
        ])

        await service.performSyncForTests(limitedTo: [.eventKit])
        let allowed = await service.syncNowForTests()

        XCTAssertTrue(allowed, "a background calendar change must not disable the refresh button")
    }

    /// The throttle still has to work for the traffic it was written for.
    func testFullSyncStillThrottlesAnImmediateManualRefresh() async {
        let exchange = account("Exchange", type: .owa)
        let service = makeService(providers: [
            StubProvider(account: exchange, events: [event(id: "exchange-1", accountID: exchange.id)])
        ])

        await service.performSyncForTests()
        let allowed = await service.syncNowForTests()

        XCTAssertFalse(allowed)
    }
}
