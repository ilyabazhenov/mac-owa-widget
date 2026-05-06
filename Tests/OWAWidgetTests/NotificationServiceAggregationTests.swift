import XCTest
@preconcurrency import UserNotifications
@testable import OWAWidget

final class NotificationServiceAggregationTests: XCTestCase {
    private let accountID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

    func testScheduleNotificationsCreatesSingleRequestForCluster() async throws {
        let center = MockNotificationCenter()
        let service = NotificationService(center: center)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let first = makeEvent(id: "a", start: now.addingTimeInterval(600), joinURL: URL(string: "https://a"))
        let second = makeEvent(id: "b", start: now.addingTimeInterval(840), joinURL: URL(string: "https://b")) // +4m

        await service.scheduleNotifications(for: [first, second], leadMinutes: 5)
        let added = center.addedRequestsSnapshot()

        XCTAssertEqual(added.count, 1)
    }

    // Calling scheduleNotifications twice for the same events must not produce duplicates.
    // Regression test for catch-up logic creating a second notification after delivery.
    func testScheduleNotificationsCalledTwiceProducesNoDuplicates() async {
        let center = MockNotificationCenter()
        let service = NotificationService(center: center)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let event = makeEvent(id: "a", start: now.addingTimeInterval(600), joinURL: URL(string: "https://a"))

        await service.scheduleNotifications(for: [event], leadMinutes: 5)
        // Simulate the first notification having fired: remove it from pending.
        await service.removeAllPendingMeetingNotifications()
        // Second sync fires — same event, still within endDate.
        await service.scheduleNotifications(for: [event], leadMinutes: 5)

        // Must have only 1 pending notification (the second schedule), not 2.
        let pending = await center.pendingRequestsSnapshot()
        XCTAssertEqual(pending.count, 1)
    }

    func testScheduleNotificationsEncodesMeetingItemsIntoUserInfo() async throws {
        let center = MockNotificationCenter()
        let service = NotificationService(center: center)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let first = makeEvent(id: "a", start: now.addingTimeInterval(600), joinURL: URL(string: "https://a"))
        let second = makeEvent(id: "b", start: now.addingTimeInterval(840), joinURL: nil)

        await service.scheduleNotifications(for: [first, second], leadMinutes: 5)
        let added = center.addedRequestsSnapshot()
        let request = try XCTUnwrap(added.first)
        let raw = try XCTUnwrap(request.content.userInfo[NotificationService.itemsUserInfoKey] as? String)
        let data = try XCTUnwrap(raw.data(using: .utf8))
        let items = try JSONDecoder().decode([MeetingReminderItem].self, from: data)

        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items.map(\.eventID), ["a", "b"])
    }

    private func makeEvent(id: String, start: Date, joinURL: URL?) -> CalendarEvent {
        CalendarEvent(
            id: id,
            title: "Meeting \(id)",
            startDate: start,
            endDate: start.addingTimeInterval(1800),
            location: nil,
            bodyPreview: nil,
            joinURL: joinURL,
            platform: .teams,
            isAllDay: false,
            organizer: nil,
            accountID: accountID
        )
    }
}

private final class MockNotificationCenter: UserNotificationCentering, @unchecked Sendable {
    private let queue = DispatchQueue(label: "MockNotificationCenter.queue")
    private var categories: Set<UNNotificationCategory> = []
    private var pending: [UNNotificationRequest] = []
    private var allAdded: [UNNotificationRequest] = []

    func setNotificationCategories(_ categories: Set<UNNotificationCategory>) {
        queue.sync { self.categories = categories }
    }

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool { true }

    func pendingNotificationRequests() async -> [UNNotificationRequest] {
        queue.sync { pending }
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        queue.sync {
            pending.removeAll { identifiers.contains($0.identifier) }
        }
    }

    func add(_ request: UNNotificationRequest) async throws {
        queue.sync {
            // Replace existing pending request with same ID (mirrors UNUserNotificationCenter behaviour).
            pending.removeAll { $0.identifier == request.identifier }
            pending.append(request)
            allAdded.append(request)
        }
    }

    /// All requests ever added (including replaced ones), for asserting schedule calls.
    func addedRequestsSnapshot() -> [UNNotificationRequest] {
        queue.sync { allAdded }
    }

    /// Currently pending requests, mirrors what UNUserNotificationCenter.pendingNotificationRequests() returns.
    func pendingRequestsSnapshot() -> [UNNotificationRequest] {
        queue.sync { pending }
    }
}
