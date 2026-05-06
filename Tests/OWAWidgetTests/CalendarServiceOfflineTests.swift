import XCTest
@testable import OWAWidget

@MainActor
final class CalendarServiceOfflineTests: XCTestCase {
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
    func cancelAll() {}
    func reschedule(
        events: [CalendarEvent],
        leadMinutes: Int,
        localization: NotificationLocalization,
        sound: MeetingReminderSound
    ) {}
}
