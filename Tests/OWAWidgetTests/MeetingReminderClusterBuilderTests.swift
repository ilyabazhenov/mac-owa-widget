import XCTest
@testable import OWAWidget

final class MeetingReminderClusterBuilderTests: XCTestCase {
    private let accountID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    func testClustersMergeEventsWithinSimultaneousWindow() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let first = makeEvent(id: "a", start: now.addingTimeInterval(600), joinURL: URL(string: "https://a"))
        // `simultaneousWindow` is 10 minutes; +4m keeps both in one cluster.
        let second = makeEvent(id: "b", start: now.addingTimeInterval(840), joinURL: URL(string: "https://b"))

        let clusters = MeetingReminderClusterBuilder.clusters(from: [first, second], now: now)

        XCTAssertEqual(clusters.count, 1)
        XCTAssertEqual(clusters[0].items.count, 2)
    }

    func testClustersSplitEventsOutsideSimultaneousWindow() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let first = makeEvent(id: "a", start: now.addingTimeInterval(600), joinURL: URL(string: "https://a"))
        // More than `MeetingReminderClusterBuilder.simultaneousWindow` after first start.
        let second = makeEvent(id: "b", start: first.startDate.addingTimeInterval(601), joinURL: URL(string: "https://b"))

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

    func testCancelledEventsExcludedFromClusters() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let active = makeEvent(id: "a", start: now.addingTimeInterval(600), joinURL: URL(string: "https://a"))
        let cancelled = makeEvent(
            id: "b",
            start: now.addingTimeInterval(660),
            joinURL: URL(string: "https://b"),
            isCancelled: true
        )

        let clusters = MeetingReminderClusterBuilder.clusters(from: [active, cancelled], now: now)

        XCTAssertEqual(clusters.count, 1)
        XCTAssertEqual(clusters[0].items.count, 1)
        XCTAssertEqual(clusters[0].items.first?.eventID, "a")
    }

    // MARK: - Suppression key stability

    func testClusterIDChangesWhenJoinURLAddedButSortedItemIDsRemainStable() {
        // Documents the root cause of duplicate reminder panels:
        // clusterID depends on item sort order (joinURL items sort first), so adding a
        // joinURL between two syncs changes the clusterID. Using sorted event IDs as the
        // suppression key instead is immune to this ordering change.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let start = now.addingTimeInterval(600)
        let eventA = makeEvent(id: "a", start: start, joinURL: nil)
        let eventB = makeEvent(id: "b", start: start.addingTimeInterval(60), joinURL: nil)

        let clusters1 = MeetingReminderClusterBuilder.clusters(from: [eventA, eventB], now: now)
        XCTAssertEqual(clusters1.count, 1, "Events within simultaneousWindow form one cluster")

        // Same events — event B now has a joinURL (detected on the next sync).
        let eventBWithURL = makeEvent(id: "b", start: start.addingTimeInterval(60),
                                      joinURL: URL(string: "https://teams.example.com/join"))
        let clusters2 = MeetingReminderClusterBuilder.clusters(from: [eventA, eventBWithURL], now: now)
        XCTAssertEqual(clusters2.count, 1)

        let cluster1 = try! XCTUnwrap(clusters1.first)
        let cluster2 = try! XCTUnwrap(clusters2.first)

        // clusterID is NOT stable: sort order changed because B now has joinURL.
        XCTAssertNotEqual(cluster1.id, cluster2.id, "clusterID changes when joinURL is added to an item")

        // But sorted item IDs ARE stable — this is what suppressionKey uses.
        let sorted1 = cluster1.items.map(\.eventID).sorted().joined(separator: "|")
        let sorted2 = cluster2.items.map(\.eventID).sorted().joined(separator: "|")
        XCTAssertEqual(sorted1, sorted2, "Sorted event IDs are stable across sort-order changes")
    }

    private func makeEvent(id: String, start: Date, joinURL: URL?, isCancelled: Bool = false) -> CalendarEvent {
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
            accountID: accountID,
            isCancelled: isCancelled
        )
    }
}
