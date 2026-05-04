import XCTest
@testable import OWAWidget

final class MeetingReminderScheduleTests: XCTestCase {
    private let accountID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

    func testDeliveryDelaySkipsAllDay() {
        let now = Date()
        let event = CalendarEvent(
            id: "1",
            title: "All day",
            startDate: now,
            endDate: now.addingTimeInterval(86_400),
            location: nil,
            bodyPreview: nil,
            joinURL: nil,
            platform: .generic,
            isAllDay: true,
            organizer: nil,
            accountID: accountID
        )
        XCTAssertNil(MeetingReminderSchedule.deliveryDelay(event: event, leadMinutes: 5, from: now))
    }

    func testDeliveryDelayInsideLeadWindowUsesCatchUp() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let start = now.addingTimeInterval(45)
        let event = CalendarEvent(
            id: "2",
            title: "Soon",
            startDate: start,
            endDate: start.addingTimeInterval(3_600),
            location: nil,
            bodyPreview: nil,
            joinURL: nil,
            platform: .generic,
            isAllDay: false,
            organizer: nil,
            accountID: accountID
        )
        let delay = MeetingReminderSchedule.deliveryDelay(event: event, leadMinutes: 1, from: now)
        XCTAssertNotNil(delay)
        XCTAssertGreaterThanOrEqual(delay!, 1)
        XCTAssertLessThanOrEqual(delay!, start.timeIntervalSince(now))
    }

    func testDeliveryDelayUsesIdealFireWhenFarAhead() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let start = now.addingTimeInterval(600)
        let event = CalendarEvent(
            id: "3",
            title: "Later",
            startDate: start,
            endDate: start.addingTimeInterval(3_600),
            location: nil,
            bodyPreview: nil,
            joinURL: nil,
            platform: .generic,
            isAllDay: false,
            organizer: nil,
            accountID: accountID
        )
        let delay = try XCTUnwrap(MeetingReminderSchedule.deliveryDelay(event: event, leadMinutes: 5, from: now))
        XCTAssertEqual(delay, 300, accuracy: 0.001)
    }
}
