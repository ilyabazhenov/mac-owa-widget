import XCTest
@testable import OWAWidget

/// Fallback order for a Join click after notifications stopped carrying meeting payloads.
///
/// The regression these pin down: with only identifiers in `userInfo`, resolution against the
/// event cache can come up empty, and an earlier version of the handler returned silently in that
/// case — the user clicked Join and absolutely nothing happened.
final class NotificationJoinActionTests: XCTestCase {

    private func makeItem(_ id: String) -> MeetingReminderItem {
        MeetingReminderItem(
            eventID: id,
            title: "Meeting \(id)",
            startDate: Date(timeIntervalSince1970: 100),
            endDate: Date(timeIntervalSince1970: 200),
            platform: .teams,
            joinURL: URL(string: "https://meet.example.com/\(id)")
        )
    }

    func testSingleResolvedItemJoinsDirectly() {
        let action = AppNotificationDelegate.joinAction(
            resolved: [makeItem("a")],
            legacy: nil,
            carriedURL: nil
        )
        XCTAssertEqual(action, .join(makeItem("a")))
    }

    func testSeveralResolvedItemsOfferAChoice() {
        let items = [makeItem("a"), makeItem("b")]
        let action = AppNotificationDelegate.joinAction(resolved: items, legacy: nil, carriedURL: nil)
        XCTAssertEqual(action, .choose(items))
    }

    func testResolvedItemsWinOverLegacyPayload() {
        let action = AppNotificationDelegate.joinAction(
            resolved: [makeItem("fresh")],
            legacy: [makeItem("stale")],
            carriedURL: nil
        )
        XCTAssertEqual(action, .join(makeItem("fresh")))
    }

    func testLegacyPayloadIsUsedWhenCacheResolvesNothing() {
        // A reminder scheduled by the previous build still carries its meetings inline.
        let action = AppNotificationDelegate.joinAction(
            resolved: [],
            legacy: [makeItem("legacy")],
            carriedURL: nil
        )
        XCTAssertEqual(action, .join(makeItem("legacy")))
    }

    func testCarriedURLIsUsedWhenNothingElseResolves() {
        let url = URL(string: "https://meet.example.com/direct")!
        let action = AppNotificationDelegate.joinAction(resolved: [], legacy: nil, carriedURL: url)
        XCTAssertEqual(action, .open(url))
    }

    func testCarriedURLIsUsedWhenLegacyPayloadIsEmpty() {
        let url = URL(string: "https://meet.example.com/direct")!
        let action = AppNotificationDelegate.joinAction(resolved: [], legacy: [], carriedURL: url)
        XCTAssertEqual(action, .open(url))
    }

    func testNothingResolvableReportsUnresolvedRatherThanSilence() {
        // The event cache is empty or undecryptable and the notification carried nothing else.
        // The outcome must be an explicit, diagnosable state — not a no-op.
        let action = AppNotificationDelegate.joinAction(resolved: [], legacy: nil, carriedURL: nil)
        XCTAssertEqual(action, .unresolved)
    }
}
