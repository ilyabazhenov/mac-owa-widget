import XCTest
@testable import OWAWidget

final class EventCacheStoreTests: XCTestCase {
    func testLoadReturnsNilWhenCacheIsMissing() {
        let defaults = UserDefaults(suiteName: "EventCacheStoreTests.missing")!
        defaults.removePersistentDomain(forName: "EventCacheStoreTests.missing")
        let store = EventCacheStore(userDefaults: defaults, key: "cache")

        XCTAssertNil(store.load())
    }

    func testSaveThenLoadReturnsSameEventsAndMetadata() throws {
        let defaults = UserDefaults(suiteName: "EventCacheStoreTests.roundtrip")!
        defaults.removePersistentDomain(forName: "EventCacheStoreTests.roundtrip")
        let store = EventCacheStore(userDefaults: defaults, key: "cache")

        let rangeStart = Date(timeIntervalSince1970: 1_710_000_000)
        let rangeEnd = Date(timeIntervalSince1970: 1_710_000_000 + 3600)
        let event = CalendarEvent(
            id: "evt-1",
            title: "Daily Sync",
            startDate: rangeStart,
            endDate: rangeStart.addingTimeInterval(1800),
            location: "Room 101",
            bodyPreview: "Status review",
            joinURL: URL(string: "https://meet.example.com/abc"),
            platform: .teams,
            isAllDay: false,
            organizer: "Alex",
            attendees: ["Max", "Ilya"],
            accountID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        )

        store.save(events: [event], rangeStart: rangeStart, rangeEnd: rangeEnd)
        let loaded = try XCTUnwrap(store.load())

        XCTAssertEqual(loaded.events, [event])
        XCTAssertEqual(loaded.rangeStart, rangeStart)
        XCTAssertEqual(loaded.rangeEnd, rangeEnd)
    }

    func testClearRemovesSavedSnapshot() {
        let defaults = UserDefaults(suiteName: "EventCacheStoreTests.clear")!
        defaults.removePersistentDomain(forName: "EventCacheStoreTests.clear")
        let store = EventCacheStore(userDefaults: defaults, key: "cache")

        store.save(events: [], rangeStart: .distantPast, rangeEnd: .distantFuture)
        XCTAssertNotNil(store.load())
        store.clear()

        XCTAssertNil(store.load())
    }

    func testLoadReturnsNilForCorruptedPayload() {
        let suite = "EventCacheStoreTests.corrupted"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = EventCacheStore(userDefaults: defaults, key: "cache")
        defaults.set(Data([0x01, 0x02, 0x03]), forKey: "cache")

        XCTAssertNil(store.load())
    }

    func testLoadReturnsNilForUnsupportedVersion() throws {
        let suite = "EventCacheStoreTests.version"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = EventCacheStore(userDefaults: defaults, key: "cache")
        let payload = """
        {
          "version": 999,
          "savedAt": 1710000000,
          "rangeStart": 1710000000,
          "rangeEnd": 1710003600,
          "events": []
        }
        """
        defaults.set(try XCTUnwrap(payload.data(using: .utf8)), forKey: "cache")

        XCTAssertNil(store.load())
    }
}
