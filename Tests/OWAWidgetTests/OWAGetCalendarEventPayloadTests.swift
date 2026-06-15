import XCTest
@testable import OWAWidget

/// Guards the request body shape for `GetCalendarEvent` (the calendar-peek request that returns
/// attendees). The structure mirrors the OWA web client; a drift here means the server rejects it.
final class OWAGetCalendarEventPayloadTests: XCTestCase {

    func testBuildsRequestWithEventIdAndChangeKey() {
        let payload = OWAGetCalendarEventPayload.make(
            itemId: "ABC",
            changeKey: "CK1",
            timezoneID: "Russian Standard Time"
        )

        XCTAssertEqual(payload["__type"] as? String, "GetCalendarEventJsonRequest:#Exchange")

        let body = payload["Body"] as? [String: Any]
        XCTAssertEqual(body?["__type"] as? String, "GetCalendarEventRequest:#Exchange")

        let eventIds = body?["EventIds"] as? [[String: Any]]
        XCTAssertEqual(eventIds?.count, 1)
        XCTAssertEqual(eventIds?.first?["__type"] as? String, "ItemId:#Exchange")
        XCTAssertEqual(eventIds?.first?["Id"] as? String, "ABC")
        XCTAssertEqual(eventIds?.first?["ChangeKey"] as? String, "CK1")

        let shape = body?["ItemShape"] as? [String: Any]
        XCTAssertEqual(shape?["__type"] as? String, "ItemResponseShape:#Exchange")
        XCTAssertEqual(shape?["BaseShape"] as? String, "IdOnly")
    }

    func testOmitsChangeKeyWhenNil() {
        let payload = OWAGetCalendarEventPayload.make(
            itemId: "ABC",
            changeKey: nil,
            timezoneID: "Russian Standard Time"
        )
        let body = payload["Body"] as? [String: Any]
        let eventIds = body?["EventIds"] as? [[String: Any]]
        XCTAssertEqual(eventIds?.first?["Id"] as? String, "ABC")
        XCTAssertNil(eventIds?.first?["ChangeKey"])
    }
}
