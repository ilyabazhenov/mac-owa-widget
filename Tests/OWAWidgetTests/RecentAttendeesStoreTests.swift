import XCTest
@testable import OWAWidget

final class RecentAttendeesStoreTests: XCTestCase {

    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        let name = "com.owawidget.tests.recent.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: name)!
    }

    func testRecordPrependsAndDedupesByEmail() {
        let a = ResolvedAttendee(displayName: "A", email: "a@x.com", jobTitle: nil)
        let b = ResolvedAttendee(displayName: "B", email: "b@x.com", jobTitle: nil)
        RecentAttendeesStore.record([a, b], defaults: defaults)
        RecentAttendeesStore.record([ResolvedAttendee(displayName: "A2", email: "a@x.com", jobTitle: "T")], defaults: defaults)
        let list = RecentAttendeesStore.load(defaults: defaults)
        XCTAssertEqual(list.map(\.attendee.email), ["a@x.com", "b@x.com"])
        XCTAssertEqual(list.first?.attendee.displayName, "A2")
    }

    func testTrimsToMaxFifteen() {
        let people = (0..<20).map { i in
            ResolvedAttendee(displayName: "U\(i)", email: "u\(i)@x.com", jobTitle: nil)
        }
        RecentAttendeesStore.record(people, defaults: defaults)
        XCTAssertEqual(RecentAttendeesStore.load(defaults: defaults).count, 20)
    }

    func testEmptyRecordNoOp() {
        XCTAssertTrue(RecentAttendeesStore.load(defaults: defaults).isEmpty)
        RecentAttendeesStore.record([], defaults: defaults)
        XCTAssertTrue(RecentAttendeesStore.load(defaults: defaults).isEmpty)
    }
}
