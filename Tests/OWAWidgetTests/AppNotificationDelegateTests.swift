import XCTest
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
}
