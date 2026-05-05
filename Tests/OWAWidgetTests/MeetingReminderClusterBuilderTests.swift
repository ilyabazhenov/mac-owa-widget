import XCTest
@testable import OWAWidget

final class MeetingReminderClusterBuilderTests: XCTestCase {
    private let accountID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    func testClustersMergeEventsWithinFiveMinutes() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let first = makeEvent(id: "a", start: now.addingTimeInterval(600), joinURL: URL(string: "https://a"))
        let second = makeEvent(id: "b", start: now.addingTimeInterval(840), joinURL: URL(string: "https://b")) // +4m

        let clusters = MeetingReminderClusterBuilder.clusters(from: [first, second], now: now)

        XCTAssertEqual(clusters.count, 1)
        XCTAssertEqual(clusters[0].items.count, 2)
    }

    func testClustersSplitEventsOutsideFiveMinutes() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let first = makeEvent(id: "a", start: now.addingTimeInterval(600), joinURL: URL(string: "https://a"))
        let second = makeEvent(id: "b", start: now.addingTimeInterval(960), joinURL: URL(string: "https://b")) // +6m

        let clusters = MeetingReminderClusterBuilder.clusters(from: [first, second], now: now)

        XCTAssertEqual(clusters.count, 2)
    }

    func testClusterDeliveryDelayUsesAnchorEvent() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let first = makeEvent(id: "a", start: now.addingTimeInterval(600), joinURL: URL(string: "https://a"))
        let second = makeEvent(id: "b", start: now.addingTimeInterval(780), joinURL: URL(string: "https://b"))

        let cluster = try XCTUnwrap(MeetingReminderClusterBuilder.clusters(from: [first, second], now: now).first)
        let delay = try XCTUnwrap(MeetingReminderSchedule.deliveryDelay(event: cluster.anchorEvent, leadMinutes: 5, from: now))

        XCTAssertEqual(delay, 300, accuracy: 0.001)
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
