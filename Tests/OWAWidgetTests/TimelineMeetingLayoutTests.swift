import XCTest
@testable import OWAWidget

final class TimelineMeetingLayoutTests: XCTestCase {
    func testClustersChainedOverlappingEventsTogether() {
        let events = [
            event(id: "a", startMinute: 10 * 60, endMinute: 10 * 60 + 30),
            event(id: "b", startMinute: 10 * 60 + 20, endMinute: 10 * 60 + 50),
            event(id: "c", startMinute: 10 * 60 + 45, endMinute: 11 * 60 + 15),
            event(id: "d", startMinute: 11 * 60 + 30, endMinute: 12 * 60),
        ]

        let clusters = TimelineMeetingLayout.makeClusters(events: events)

        XCTAssertEqual(clusters.count, 2)
        XCTAssertEqual(clusters[0].items.map(\.event.id), ["a", "b", "c"])
        XCTAssertEqual(clusters[0].startDate, events[0].startDate)
        XCTAssertEqual(clusters[0].endDate, events[2].endDate)
        XCTAssertEqual(clusters[1].items.map(\.event.id), ["d"])
    }

    func testAssignsOverlappingEventsToOneRowColumns() {
        let events = [
            event(id: "a", startMinute: 10 * 60, endMinute: 10 * 60 + 30),
            event(id: "b", startMinute: 10 * 60 + 20, endMinute: 10 * 60 + 50),
            event(id: "c", startMinute: 10 * 60 + 45, endMinute: 11 * 60 + 15),
        ]

        let cluster = TimelineMeetingLayout.makeClusters(events: events)[0]

        XCTAssertEqual(cluster.rowCount, 1)
        XCTAssertEqual(cluster.items.map(\.column), [0, 1, 2])
        XCTAssertEqual(cluster.items.map(\.columnCount), [3, 3, 3])
    }

    func testCalculatesOffsetAndWidthFractionsWithinCluster() {
        let events = [
            event(id: "a", startMinute: 10 * 60, endMinute: 10 * 60 + 30),
            event(id: "b", startMinute: 10 * 60 + 30, endMinute: 11 * 60 + 30),
        ]

        let clusters = TimelineMeetingLayout.makeClusters(events: events)

        XCTAssertEqual(clusters.count, 2)
        XCTAssertEqual(clusters[0].items[0].offsetFraction, 0, accuracy: 0.001)
        XCTAssertEqual(clusters[0].items[0].widthFraction, 1, accuracy: 0.001)
        XCTAssertEqual(clusters[1].items[0].offsetFraction, 0, accuracy: 0.001)
        XCTAssertEqual(clusters[1].items[0].widthFraction, 1, accuracy: 0.001)
    }

    private func event(id: String, startMinute: Int, endMinute: Int) -> CalendarEvent {
        CalendarEvent(
            id: id,
            title: "Event \(id)",
            startDate: Date(timeIntervalSince1970: TimeInterval(startMinute * 60)),
            endDate: Date(timeIntervalSince1970: TimeInterval(endMinute * 60)),
            location: nil,
            bodyPreview: nil,
            joinURL: nil,
            platform: .generic,
            isAllDay: false,
            organizer: nil,
            accountID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        )
    }
}
