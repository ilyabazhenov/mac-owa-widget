import XCTest
@testable import OWAWidget

final class RecentAttendeesStoreTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!
    private var directory: URL!
    private var store: RecentAttendeesStore.Store!

    override func setUp() {
        super.setUp()
        suiteName = "com.owawidget.tests.recent.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("recentattendees-tests-\(UUID().uuidString)", isDirectory: true)
        store = RecentAttendeesStore.makeStore(
            secureStore: SecureStore(directory: directory, keyProvider: InMemorySecureStoreKeyProvider()),
            defaults: defaults
        )
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        if let directory { try? FileManager.default.removeItem(at: directory) }
        super.tearDown()
    }

    func testRecordPrependsAndDedupesByEmail() {
        let a = ResolvedAttendee(displayName: "A", email: "a@x.com", jobTitle: nil)
        let b = ResolvedAttendee(displayName: "B", email: "b@x.com", jobTitle: nil)
        RecentAttendeesStore.record([a, b], store: store)
        RecentAttendeesStore.record([ResolvedAttendee(displayName: "A2", email: "a@x.com", jobTitle: "T")], store: store)
        let list = RecentAttendeesStore.load(store: store)
        XCTAssertEqual(list.map(\.attendee.email), ["a@x.com", "b@x.com"])
        XCTAssertEqual(list.first?.attendee.displayName, "A2")
    }

    func testTrimsToMaxFifteen() {
        let people = (0..<20).map { i in
            ResolvedAttendee(displayName: "U\(i)", email: "u\(i)@x.com", jobTitle: nil)
        }
        RecentAttendeesStore.record(people, store: store)
        XCTAssertEqual(RecentAttendeesStore.load(store: store).count, 20)
    }

    func testEmptyRecordNoOp() {
        XCTAssertTrue(RecentAttendeesStore.load(store: store).isEmpty)
        RecentAttendeesStore.record([], store: store)
        XCTAssertTrue(RecentAttendeesStore.load(store: store).isEmpty)
    }

    // MARK: - Migration

    func testLegacyCleartextHistoryIsMigratedAndRemoved() throws {
        let records = [
            AttendeeRecord(
                attendee: ResolvedAttendee(displayName: "Коллега", email: "c@x.com", jobTitle: "Аналитик"),
                useCount: 4,
                lastUsed: Date(timeIntervalSince1970: 1_700_000_000)
            )
        ]
        defaults.set(try JSONEncoder().encode(records), forKey: RecentAttendeesStore.legacyDefaultsKey)

        XCTAssertEqual(RecentAttendeesStore.load(store: store).map(\.attendee.email), ["c@x.com"])
        XCTAssertNil(
            defaults.data(forKey: RecentAttendeesStore.legacyDefaultsKey),
            "адреса коллег остались в UserDefaults открытым текстом"
        )
    }

    func testOldestFormatIsFoldedForwardThenEncrypted() throws {
        // Pre-counter shape: a bare [ResolvedAttendee] under the original key.
        let legacy = [ResolvedAttendee(displayName: "Старый", email: "old@x.com", jobTitle: nil)]
        defaults.set(try JSONEncoder().encode(legacy), forKey: RecentAttendeesStore.olderLegacyDefaultsKey)

        let migrating = RecentAttendeesStore.makeStore(
            secureStore: SecureStore(directory: directory, keyProvider: InMemorySecureStoreKeyProvider()),
            defaults: defaults
        )
        XCTAssertEqual(RecentAttendeesStore.load(store: migrating).map(\.attendee.email), ["old@x.com"])
        XCTAssertNil(defaults.data(forKey: RecentAttendeesStore.olderLegacyDefaultsKey))
        XCTAssertNil(defaults.data(forKey: RecentAttendeesStore.legacyDefaultsKey))
    }
}
