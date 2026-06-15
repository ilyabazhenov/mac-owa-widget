import XCTest
@testable import OWAWidget

@MainActor
final class CalendarServiceOfflineTests: XCTestCase {
    override func tearDown() {
        super.tearDown()
        UserDefaults.standard.removeObject(forKey: "meetingReminderStyle")
        UserDefaults.standard.removeObject(forKey: "menuBarDisplayMode")
    }

    func testInitRestoresEventsFromCache() {
        let cachedEvent = makeEvent(id: "cached-init")
        let cache = InMemoryEventCacheStore(
            snapshot: EventCacheSnapshot(
                version: 1,
                savedAt: Date(timeIntervalSince1970: 100),
                rangeStart: Date(timeIntervalSince1970: 50),
                rangeEnd: Date(timeIntervalSince1970: 150),
                events: [cachedEvent]
            )
        )

        let service = CalendarService(
            providers: [],
            eventCacheStore: cache,
            notificationService: NoOpNotificationService(),
            customMeetingReminders: NoOpMeetingReminderController(),
            loadPersistedAccounts: false,
            startBackgroundTasks: false
        )

        XCTAssertEqual(service.events, [cachedEvent])
    }

    func testFailedSyncFallsBackToCachedEventsWhenMemoryIsEmpty() async {
        let cachedEvent = makeEvent(id: "cached-fallback")
        let cache = InMemoryEventCacheStore(
            snapshot: EventCacheSnapshot(
                version: 1,
                savedAt: Date(timeIntervalSince1970: 100),
                rangeStart: Date(timeIntervalSince1970: 50),
                rangeEnd: Date(timeIntervalSince1970: 150),
                events: [cachedEvent]
            )
        )

        let service = CalendarService(
            providers: [FailingProvider()],
            eventCacheStore: cache,
            notificationService: NoOpNotificationService(),
            customMeetingReminders: NoOpMeetingReminderController(),
            loadPersistedAccounts: false,
            startBackgroundTasks: false
        )
        service.replaceEventsForTests([])

        await service.performSyncForTests()

        XCTAssertEqual(service.events, [cachedEvent])
        guard case .offlineCached = service.syncStatus else {
            return XCTFail("Expected offlineCached status")
        }
    }

    func testSuccessfulSyncPersistsEventsToCache() async {
        let fetchedEvent = makeEvent(id: "fetched-event")
        let cache = InMemoryEventCacheStore(snapshot: nil)
        let service = CalendarService(
            providers: [SuccessfulProvider(events: [fetchedEvent])],
            eventCacheStore: cache,
            notificationService: NoOpNotificationService(),
            customMeetingReminders: NoOpMeetingReminderController(),
            loadPersistedAccounts: false,
            startBackgroundTasks: false
        )

        await service.performSyncForTests()

        XCTAssertEqual(service.events, [fetchedEvent])
        XCTAssertEqual(cache.snapshot?.events, [fetchedEvent])
    }

    func testFailedSyncWithoutCacheSetsErrorStatus() async {
        let cache = InMemoryEventCacheStore(snapshot: nil)
        let service = CalendarService(
            providers: [FailingProvider()],
            eventCacheStore: cache,
            notificationService: NoOpNotificationService(),
            customMeetingReminders: NoOpMeetingReminderController(),
            loadPersistedAccounts: false,
            startBackgroundTasks: false
        )
        service.replaceEventsForTests([])

        await service.performSyncForTests()

        XCTAssertTrue(service.events.isEmpty)
        guard case .error = service.syncStatus else {
            return XCTFail("Expected error status when cache is absent")
        }
    }

    func testLegacyReminderStyleMigratesSilentlyToInApp() {
        UserDefaults.standard.set("both", forKey: "meetingReminderStyle")
        let service = CalendarService(
            providers: [],
            eventCacheStore: InMemoryEventCacheStore(snapshot: nil),
            notificationService: NoOpNotificationService(),
            customMeetingReminders: NoOpMeetingReminderController(),
            loadPersistedAccounts: false,
            startBackgroundTasks: false
        )

        XCTAssertEqual(service.meetingReminderStyle, .inApp)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "meetingReminderStyle"), MeetingReminderStyle.inApp.rawValue)
    }

    func testSyncWithoutProvidersClosesActiveReminder() async {
        let reminderController = RecordingMeetingReminderController()
        let service = CalendarService(
            providers: [],
            eventCacheStore: InMemoryEventCacheStore(snapshot: nil),
            notificationService: NoOpNotificationService(),
            customMeetingReminders: reminderController,
            loadPersistedAccounts: false,
            startBackgroundTasks: false
        )

        await service.performSyncForTests()

        XCTAssertEqual(reminderController.cancelCalls, [true])
    }

    func testFailedSyncReschedulesRemindersFromMemoryEvents() async {
        let memoryEvent = makeEvent(id: "memory-event")
        let reminderController = RecordingMeetingReminderController()
        let service = CalendarService(
            providers: [FailingProvider()],
            eventCacheStore: InMemoryEventCacheStore(snapshot: nil),
            notificationService: NoOpNotificationService(),
            customMeetingReminders: reminderController,
            loadPersistedAccounts: false,
            startBackgroundTasks: false
        )
        service.replaceEventsForTests([memoryEvent])

        await service.performSyncForTests()

        XCTAssertEqual(reminderController.rescheduledEvents, [[memoryEvent]])
    }

    func testFailedSyncReschedulesRemindersFromDiskCacheWhenMemoryEmpty() async {
        let cachedEvent = makeEvent(id: "disk-cached-event")
        let cache = InMemoryEventCacheStore(
            snapshot: EventCacheSnapshot(
                version: 1,
                savedAt: Date(timeIntervalSince1970: 100),
                rangeStart: Date(timeIntervalSince1970: 50),
                rangeEnd: Date(timeIntervalSince1970: 150),
                events: [cachedEvent]
            )
        )
        let reminderController = RecordingMeetingReminderController()
        let service = CalendarService(
            providers: [FailingProvider()],
            eventCacheStore: cache,
            notificationService: NoOpNotificationService(),
            customMeetingReminders: reminderController,
            loadPersistedAccounts: false,
            startBackgroundTasks: false
        )
        service.replaceEventsForTests([])

        await service.performSyncForTests()

        XCTAssertEqual(reminderController.rescheduledEvents, [[cachedEvent]])
    }

    func testAuthFailureSetsAuthenticationRequiredStatus() async {
        let service = CalendarService(
            providers: [AuthFailingProvider()],
            eventCacheStore: InMemoryEventCacheStore(snapshot: nil),
            notificationService: NoOpNotificationService(),
            customMeetingReminders: NoOpMeetingReminderController(),
            loadPersistedAccounts: false,
            startBackgroundTasks: false
        )

        await service.performSyncForTests()

        XCTAssertTrue(service.syncStatus.isAuthenticationRequired)
    }

    func testAuthCircuitBreakerStopsSubsequentSyncs() async {
        let provider = AuthFailingProvider()
        let service = CalendarService(
            providers: [provider],
            eventCacheStore: InMemoryEventCacheStore(snapshot: nil),
            notificationService: NoOpNotificationService(),
            customMeetingReminders: NoOpMeetingReminderController(),
            loadPersistedAccounts: false,
            startBackgroundTasks: false
        )

        // First sync triggers the auth error and sets the circuit breaker.
        await service.performSyncForTests()
        XCTAssertTrue(service.syncStatus.isAuthenticationRequired)
        let callsAfterFirst = await provider.fetchCallCount
        XCTAssertEqual(callsAfterFirst, 1)

        // Subsequent syncs must be skipped — provider must not be called again.
        await service.performSyncForTests()
        await service.performSyncForTests()
        let callsAfterSubsequent = await provider.fetchCallCount
        XCTAssertEqual(callsAfterSubsequent, 1, "Provider must not be called after circuit breaker trips")
    }

    func testFailedSyncReschedulesRemindersEvenWithNoEvents() async {
        let reminderController = RecordingMeetingReminderController()
        let service = CalendarService(
            providers: [FailingProvider()],
            eventCacheStore: InMemoryEventCacheStore(snapshot: nil),
            notificationService: NoOpNotificationService(),
            customMeetingReminders: reminderController,
            loadPersistedAccounts: false,
            startBackgroundTasks: false
        )
        service.replaceEventsForTests([])

        await service.performSyncForTests()

        XCTAssertEqual(reminderController.rescheduledEvents, [[]])
    }

    func testMenuBarDisplayModeDefaultsToCountdown() {
        UserDefaults.standard.removeObject(forKey: "menuBarDisplayMode")
        let service = CalendarService(
            providers: [],
            eventCacheStore: InMemoryEventCacheStore(snapshot: nil),
            notificationService: NoOpNotificationService(),
            customMeetingReminders: NoOpMeetingReminderController(),
            loadPersistedAccounts: false,
            startBackgroundTasks: false
        )

        XCTAssertEqual(service.menuBarDisplayMode, .countdown)
    }

    func testMenuBarDisplayModePersistsAndRestoresFromUserDefaults() {
        UserDefaults.standard.removeObject(forKey: "menuBarDisplayMode")
        let firstService = CalendarService(
            providers: [],
            eventCacheStore: InMemoryEventCacheStore(snapshot: nil),
            notificationService: NoOpNotificationService(),
            customMeetingReminders: NoOpMeetingReminderController(),
            loadPersistedAccounts: false,
            startBackgroundTasks: false
        )
        firstService.menuBarDisplayMode = .status

        let secondService = CalendarService(
            providers: [],
            eventCacheStore: InMemoryEventCacheStore(snapshot: nil),
            notificationService: NoOpNotificationService(),
            customMeetingReminders: NoOpMeetingReminderController(),
            loadPersistedAccounts: false,
            startBackgroundTasks: false
        )

        XCTAssertEqual(secondService.menuBarDisplayMode, .status)
    }

    func testLoadAttendeesFetchesOnceThenServesFromCache() async throws {
        let attendees = [EventAttendee(name: "X", email: "x@y.z", kind: .required, response: .accepted)]
        let provider = CountingAttendeesProvider(result: attendees)
        let event = makeEvent(id: "evt", accountID: provider.account.id)
        let service = makeAttendeesService(provider: provider, events: [event])

        let first = try await service.loadAttendees(for: event)
        XCTAssertEqual(first, attendees)
        var calls = await provider.callCount
        XCTAssertEqual(calls, 1)
        // The loaded list is cached back onto the event in the store.
        XCTAssertEqual(service.events.first { $0.id == "evt" }?.detailedAttendees, attendees)

        // Re-opening passes the now-cached event; loadAttendees must short-circuit (no 2nd request).
        let cached = try XCTUnwrap(service.events.first { $0.id == "evt" })
        let second = try await service.loadAttendees(for: cached)
        XCTAssertEqual(second, attendees)
        calls = await provider.callCount
        XCTAssertEqual(calls, 1)
    }

    func testLoadAttendeesCachesEmptyResultToAvoidRefetch() async throws {
        let provider = CountingAttendeesProvider(result: [])
        let event = makeEvent(id: "evt-empty", accountID: provider.account.id)
        let service = makeAttendeesService(provider: provider, events: [event])

        _ = try await service.loadAttendees(for: event)
        // Empty list is cached as [] (not nil) so re-open does not hit the network again.
        XCTAssertEqual(service.events.first { $0.id == "evt-empty" }?.detailedAttendees, [])
        let cached = try XCTUnwrap(service.events.first { $0.id == "evt-empty" })
        _ = try await service.loadAttendees(for: cached)
        let calls = await provider.callCount
        XCTAssertEqual(calls, 1)
    }

    private func makeAttendeesService(
        provider: any CalendarProvider,
        events: [CalendarEvent]
    ) -> CalendarService {
        let service = CalendarService(
            providers: [provider],
            eventCacheStore: InMemoryEventCacheStore(snapshot: nil),
            notificationService: NoOpNotificationService(),
            customMeetingReminders: NoOpMeetingReminderController(),
            loadPersistedAccounts: false,
            startBackgroundTasks: false
        )
        service.replaceEventsForTests(events)
        return service
    }

    private func makeEvent(id: String) -> CalendarEvent {
        makeEvent(id: id, accountID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
    }

    private func makeEvent(id: String, accountID: UUID) -> CalendarEvent {
        CalendarEvent(
            id: id,
            title: "Test Event",
            startDate: Date(timeIntervalSince1970: 200),
            endDate: Date(timeIntervalSince1970: 260),
            location: nil,
            bodyPreview: nil,
            joinURL: nil,
            platform: .generic,
            isAllDay: false,
            organizer: nil,
            attendees: [],
            accountID: accountID
        )
    }
}

private actor CountingAttendeesProvider: CalendarProvider {
    let account = CalendarAccount(displayName: "Test", serverURL: "example.com", email: "a@b.c")
    private let result: [EventAttendee]
    private(set) var callCount = 0

    init(result: [EventAttendee]) {
        self.result = result
    }

    func fetchEvents(from start: Date, to end: Date) async throws -> [CalendarEvent] { [] }
    func validateCredentials() async throws {}

    func fetchAttendees(for event: CalendarEvent) async throws -> [EventAttendee] {
        callCount += 1
        return result
    }
}

private actor SuccessfulProvider: CalendarProvider {
    let account = CalendarAccount(displayName: "Test", serverURL: "example.com", email: "a@b.c")
    private let events: [CalendarEvent]

    init(events: [CalendarEvent]) {
        self.events = events
    }

    func fetchEvents(from start: Date, to end: Date) async throws -> [CalendarEvent] {
        events
    }

    func validateCredentials() async throws {}
}

private actor FailingProvider: CalendarProvider {
    let account = CalendarAccount(displayName: "Test", serverURL: "example.com", email: "a@b.c")

    func fetchEvents(from start: Date, to end: Date) async throws -> [CalendarEvent] {
        throw URLError(.notConnectedToInternet)
    }

    func validateCredentials() async throws {}
}

private actor AuthFailingProvider: CalendarProvider {
    let account = CalendarAccount(displayName: "Test", serverURL: "example.com", email: "a@b.c")
    private(set) var fetchCallCount = 0

    func fetchEvents(from start: Date, to end: Date) async throws -> [CalendarEvent] {
        fetchCallCount += 1
        throw OWAError.authenticationFailed("wrong password")
    }

    func validateCredentials() async throws {}
}

private final class InMemoryEventCacheStore: EventCacheStoring {
    var snapshot: EventCacheSnapshot?

    init(snapshot: EventCacheSnapshot?) {
        self.snapshot = snapshot
    }

    func load() -> EventCacheSnapshot? {
        snapshot
    }

    func save(events: [CalendarEvent], rangeStart: Date, rangeEnd: Date) {
        snapshot = EventCacheSnapshot(
            version: 1,
            savedAt: Date(),
            rangeStart: rangeStart,
            rangeEnd: rangeEnd,
            events: events
        )
    }

    func clear() {
        snapshot = nil
    }
}

private actor NoOpNotificationService: NotificationServicing {
    func setup(localization: NotificationLocalization) {}
    func requestAuthorization() async {}
    func removeAllPendingMeetingNotifications() async {}
    func scheduleNotifications(for events: [CalendarEvent], leadMinutes: Int, localization: NotificationLocalization) async {}
}

@MainActor
private final class NoOpMeetingReminderController: CustomMeetingReminderControlling {
    func cancelAll(closeActiveReminder: Bool) {}
    func reschedule(
        events: [CalendarEvent],
        leadMinutes: Int,
        localization: NotificationLocalization,
        sound: MeetingReminderSound
    ) {}
}

@MainActor
private final class RecordingMeetingReminderController: CustomMeetingReminderControlling {
    private(set) var cancelCalls: [Bool] = []
    private(set) var rescheduledEvents: [[CalendarEvent]] = []

    func cancelAll(closeActiveReminder: Bool) {
        cancelCalls.append(closeActiveReminder)
    }

    func reschedule(
        events: [CalendarEvent],
        leadMinutes: Int,
        localization: NotificationLocalization,
        sound: MeetingReminderSound
    ) {
        rescheduledEvents.append(events)
    }
}
