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

    private func makeEvent(id: String) -> CalendarEvent {
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
            accountID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        )
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
