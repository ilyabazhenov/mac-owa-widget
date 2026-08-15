import XCTest
@testable import OWAWidget

final class EventCacheStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("eventcache-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try super.tearDownWithError()
    }

    /// Always injects a temporary ``SecureStore`` with an in-memory key — the suite must never
    /// reach the real Keychain, or `make release-package` could stall on an authorization dialog.
    private func makeStore(defaults: UserDefaults) -> EventCacheStore {
        EventCacheStore(
            secureStore: SecureStore(directory: directory, keyProvider: InMemorySecureStoreKeyProvider()),
            userDefaults: defaults,
            name: "cache",
            legacyKey: "cache"
        )
    }

    private func makeDefaults(_ label: String) -> UserDefaults {
        let suite = "EventCacheStoreTests.\(label).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func makeEvent(start: Date) -> CalendarEvent {
        CalendarEvent(
            id: "evt-1",
            title: "Daily Sync",
            startDate: start,
            endDate: start.addingTimeInterval(1800),
            location: "Room 101",
            bodyPreview: "Status review",
            joinURL: URL(string: "https://meet.example.com/abc"),
            platform: .teams,
            isAllDay: false,
            organizer: "Alex",
            attendees: ["Max", "Ilya"],
            accountID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        )
    }

    func testLoadReturnsNilWhenCacheIsMissing() {
        XCTAssertNil(makeStore(defaults: makeDefaults("missing")).load())
    }

    func testSaveThenLoadReturnsSameEventsAndMetadata() throws {
        let store = makeStore(defaults: makeDefaults("roundtrip"))
        let rangeStart = Date(timeIntervalSince1970: 1_710_000_000)
        let rangeEnd = rangeStart.addingTimeInterval(3600)
        let event = makeEvent(start: rangeStart)

        store.save(events: [event], rangeStart: rangeStart, rangeEnd: rangeEnd)
        let loaded = try XCTUnwrap(store.load())

        XCTAssertEqual(loaded.events, [event])
        XCTAssertEqual(loaded.rangeStart, rangeStart)
        XCTAssertEqual(loaded.rangeEnd, rangeEnd)
    }

    func testClearRemovesSavedSnapshot() {
        let store = makeStore(defaults: makeDefaults("clear"))
        store.save(events: [], rangeStart: .distantPast, rangeEnd: .distantFuture)
        XCTAssertNotNil(store.load())

        store.clear()
        XCTAssertNil(store.load())
    }

    func testLoadReturnsNilForCorruptedPayload() {
        let defaults = makeDefaults("corrupted")
        let store = makeStore(defaults: defaults)
        defaults.set(Data([0x01, 0x02, 0x03]), forKey: "cache")

        XCTAssertNil(store.load())
    }

    func testLoadReturnsNilForUnsupportedVersion() throws {
        let defaults = makeDefaults("version")
        let store = makeStore(defaults: defaults)
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

    // MARK: - Migration off the cleartext plist

    func testLegacyCleartextCacheIsMigratedAndRemoved() throws {
        let defaults = makeDefaults("migration")
        let rangeStart = Date(timeIntervalSince1970: 1_710_000_000)
        let snapshot = EventCacheSnapshot(
            version: 1,
            savedAt: rangeStart,
            rangeStart: rangeStart,
            rangeEnd: rangeStart.addingTimeInterval(3600),
            events: [makeEvent(start: rangeStart)]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        defaults.set(try encoder.encode(snapshot), forKey: "cache")

        let store = makeStore(defaults: defaults)
        let loaded = try XCTUnwrap(store.load())

        XCTAssertEqual(loaded.events, snapshot.events)
        XCTAssertNil(defaults.data(forKey: "cache"), "открытая копия кэша осталась в UserDefaults")
    }

    func testMeetingContentIsNotReadableOnDisk() throws {
        let defaults = makeDefaults("ondisk")
        let secure = SecureStore(directory: directory, keyProvider: InMemorySecureStoreKeyProvider())
        let store = EventCacheStore(
            secureStore: secure,
            userDefaults: defaults,
            name: "cache",
            legacyKey: "cache"
        )
        let start = Date(timeIntervalSince1970: 1_710_000_000)
        store.save(events: [makeEvent(start: start)], rangeStart: start, rangeEnd: start)

        let raw = try Data(contentsOf: secure.url(for: "cache"))
        for secret in ["Daily Sync", "Room 101", "meet.example.com", "Status review"] {
            XCTAssertNil(raw.range(of: Data(secret.utf8)), "«\(secret)» читается на диске открытым текстом")
        }
    }
}
