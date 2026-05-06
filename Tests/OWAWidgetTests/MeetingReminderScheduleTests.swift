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

    // Catch-up was removed: events within the lead window must return nil to avoid
    // duplicate notifications when the sync cycle fires after delivery.
    func testDeliveryDelayInsideLeadWindowSkips() {
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
        XCTAssertNil(MeetingReminderSchedule.deliveryDelay(event: event, leadMinutes: 1, from: now))
    }

    // Exact boundary: secondsUntilIdealFire == 1 must skip (guard is > 1, not >= 1).
    func testDeliveryDelaySkipsAtExactBoundary() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let leadMinutes = 5
        // start - now - lead == 1 exactly → boundary
        let start = now.addingTimeInterval(TimeInterval(leadMinutes * 60) + 1)
        let event = CalendarEvent(
            id: "boundary",
            title: "Boundary",
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
        XCTAssertNil(MeetingReminderSchedule.deliveryDelay(event: event, leadMinutes: leadMinutes, from: now))
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

    // Event already started (but not ended) must skip — no catch-up notifications.
    func testDeliveryDelaySkipsAlreadyStartedEvent() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let start = now.addingTimeInterval(-120)
        let event = CalendarEvent(
            id: "started",
            title: "In progress",
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
        XCTAssertNil(MeetingReminderSchedule.deliveryDelay(event: event, leadMinutes: 1, from: now))
    }

    // Event ended must skip.
    func testDeliveryDelaySkipsCompletedEvent() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let start = now.addingTimeInterval(-3_600)
        let event = CalendarEvent(
            id: "done",
            title: "Finished",
            startDate: start,
            endDate: start.addingTimeInterval(1_800),
            location: nil,
            bodyPreview: nil,
            joinURL: nil,
            platform: .generic,
            isAllDay: false,
            organizer: nil,
            accountID: accountID
        )
        XCTAssertNil(MeetingReminderSchedule.deliveryDelay(event: event, leadMinutes: 1, from: now))
    }
}
