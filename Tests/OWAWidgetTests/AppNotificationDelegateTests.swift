import XCTest
@preconcurrency import UserNotifications
@testable import OWAWidget

final class AppNotificationDelegateTests: XCTestCase {
    func testDecodeItemsReturnsItemsForValidPayload() throws {
        let items = [
            MeetingReminderItem(
                eventID: "a",
                title: "A",
                startDate: Date(timeIntervalSince1970: 100),
                endDate: Date(timeIntervalSince1970: 200),
                platform: .teams,
                joinURL: URL(string: "https://a")
            ),
            MeetingReminderItem(
                eventID: "b",
                title: "B",
                startDate: Date(timeIntervalSince1970: 100),
                endDate: Date(timeIntervalSince1970: 200),
                platform: .zoom,
                joinURL: nil
            ),
        ]
        let raw = String(data: try JSONEncoder().encode(items), encoding: .utf8)
        let userInfo: [AnyHashable: Any] = [NotificationService.itemsUserInfoKey: raw as Any]

        let decoded = AppNotificationDelegate.decodeItems(from: userInfo)

        XCTAssertEqual(decoded?.count, 2)
        XCTAssertEqual(decoded?.map(\.eventID), ["a", "b"])
    }

    func testDecodeItemsReturnsNilForInvalidPayload() {
        let userInfo: [AnyHashable: Any] = [NotificationService.itemsUserInfoKey: "not-json"]

        let decoded = AppNotificationDelegate.decodeItems(from: userInfo)

        XCTAssertNil(decoded)
    }

    // MARK: - Identifier-only payload

    func testDecodeEventIDsReturnsIdentifiers() throws {
        let raw = String(data: try JSONEncoder().encode(["a", "b"]), encoding: .utf8)
        let userInfo: [AnyHashable: Any] = [NotificationService.eventIDsUserInfoKey: raw as Any]

        XCTAssertEqual(AppNotificationDelegate.decodeEventIDs(from: userInfo), ["a", "b"])
    }

    func testDecodeEventIDsReturnsNilForInvalidPayload() {
        let userInfo: [AnyHashable: Any] = [NotificationService.eventIDsUserInfoKey: "not-json"]

        XCTAssertNil(AppNotificationDelegate.decodeEventIDs(from: userInfo))
    }

    func testDecodeEventIDsReturnsNilWhenOnlyLegacyPayloadPresent() {
        // A reminder scheduled by the previous version: no identifiers, full payload instead.
        let userInfo: [AnyHashable: Any] = [NotificationService.itemsUserInfoKey: "[]"]

        XCTAssertNil(AppNotificationDelegate.decodeEventIDs(from: userInfo))
    }

    func testHandleNotificationActionRemovesDeliveredNotificationForJoinAction() {
        let delegate = AppNotificationDelegate()
        var removedIDs: [String] = []
        let processed = delegate.removeDeliveredForJoinAction(
            actionIdentifier: NotificationService.actionID,
            requestIdentifier: "req-1",
            removeDelivered: { removedIDs = $0 }
        )

        XCTAssertTrue(processed)
        XCTAssertEqual(removedIDs, ["req-1"])
    }

    func testHandleNotificationActionDoesNotRemoveDeliveredForNonJoinAction() {
        let delegate = AppNotificationDelegate()
        var removeCalled = false

        let processed = delegate.removeDeliveredForJoinAction(
            actionIdentifier: UNNotificationDismissActionIdentifier,
            requestIdentifier: "req-2",
            removeDelivered: { _ in removeCalled = true }
        )

        XCTAssertFalse(processed)
        XCTAssertFalse(removeCalled)
    }
}
