import XCTest
@testable import OWAWidget

/// Migration behaviour of ``SecureCodableStore``. The contract these tests pin down is the one
/// that keeps an update from looking like data loss: the cleartext copy is only removed after the
/// encrypted one has been written *and* read back successfully.
final class SecureCodableStoreTests: XCTestCase {
    private struct Payload: Codable, Equatable {
        var title: String
        var count: Int
    }

    private var directory: URL!
    private var store: SecureStore!
    private var defaults: UserDefaults!
    private var suiteName: String!

    private let legacyKey = "legacyPayloadKey"
    private let sample = Payload(title: "планёрка", count: 3)

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("securecodable-tests-\(UUID().uuidString)", isDirectory: true)
        store = SecureStore(directory: directory, keyProvider: InMemorySecureStoreKeyProvider())
        suiteName = "securecodable.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try super.tearDownWithError()
    }

    private func makeStore(
        policy: SecureCodableStore<Payload>.FailurePolicy = .fallBackToLegacy,
        secureStore: SecureStore? = nil
    ) -> SecureCodableStore<Payload> {
        SecureCodableStore<Payload>(
            name: "payload",
            legacyKey: legacyKey,
            store: secureStore ?? store,
            defaults: defaults,
            policy: policy
        )
    }

    // MARK: - Basics

    func testSaveThenLoadRoundTrips() {
        let subject = makeStore()
        XCTAssertTrue(subject.save(sample))
        XCTAssertEqual(makeStore().load(), sample)
    }

    func testLoadReturnsNilWhenNothingStored() {
        XCTAssertNil(makeStore().load())
    }

    // MARK: - Migration

    func testLegacyValueIsMigratedAndCleartextKeyRemoved() throws {
        defaults.set(try JSONEncoder().encode(sample), forKey: legacyKey)

        let subject = makeStore()
        XCTAssertEqual(subject.load(), sample)

        XCTAssertTrue(store.exists("payload"), "зашифрованный контейнер не создан")
        XCTAssertNil(defaults.data(forKey: legacyKey), "открытая копия осталась в UserDefaults")
    }

    func testMigrationIsSkippedWhenEncryptedContainerAlreadyExists() throws {
        let newer = Payload(title: "актуальное", count: 9)
        XCTAssertTrue(makeStore().save(newer))
        defaults.set(try JSONEncoder().encode(sample), forKey: legacyKey)

        // Encrypted data wins; a stale legacy key must not overwrite it.
        XCTAssertEqual(makeStore().load(), newer)
    }

    func testUndecodableLegacyDataIsNotMigrated() {
        defaults.set(Data("не json".utf8), forKey: legacyKey)

        let subject = makeStore()
        XCTAssertNil(subject.load())
        XCTAssertFalse(store.exists("payload"), "мусор из legacy не должен попадать в контейнер")
    }

    func testMigrationIsAttemptedOnlyOncePerInstance() throws {
        defaults.set(try JSONEncoder().encode(sample), forKey: legacyKey)
        let subject = makeStore()
        XCTAssertEqual(subject.load(), sample)

        // Second read must not resurrect anything from the (now empty) legacy key.
        XCTAssertEqual(subject.load(), sample)
        XCTAssertNil(defaults.data(forKey: legacyKey))
    }

    func testSaveAlsoDrainsTheLegacyKey() throws {
        // A store whose first operation is a write must still clear the cleartext predecessor.
        // Otherwise it stays in the plist forever: the next load() sees the container already
        // exists and skips migrating.
        defaults.set(try JSONEncoder().encode(sample), forKey: legacyKey)

        let subject = makeStore()
        XCTAssertTrue(subject.save(Payload(title: "новое", count: 7)))

        XCTAssertNil(defaults.data(forKey: legacyKey), "открытая копия пережила запись")
        XCTAssertEqual(makeStore().load(), Payload(title: "новое", count: 7))
    }

    func testFailedMigrationKeepsLegacyCopy() throws {
        defaults.set(try JSONEncoder().encode(sample), forKey: legacyKey)
        let broken = SecureStore(directory: directory, keyProvider: UnavailableSecureStoreKeyProvider())

        let subject = makeStore(secureStore: broken)
        // Falls back to the cleartext copy rather than reporting empty…
        XCTAssertEqual(subject.load(), sample)
        // …and crucially leaves it in place, so the next launch can retry.
        XCTAssertNotNil(defaults.data(forKey: legacyKey))
        XCTAssertFalse(broken.exists("payload"))
    }

    // MARK: - Failure policy

    func testTreatAsEmptyPolicyReportsNilOnUnreadableContainer() throws {
        XCTAssertTrue(makeStore().save(sample))
        defaults.set(try JSONEncoder().encode(sample), forKey: legacyKey)

        let otherKey = SecureStore(directory: directory, keyProvider: InMemorySecureStoreKeyProvider())
        let subject = SecureCodableStore<Payload>(
            name: "payload",
            legacyKey: legacyKey,
            store: otherKey,
            defaults: defaults,
            policy: .treatAsEmpty
        )
        XCTAssertNil(subject.load(), "регенерируемый кэш должен считаться пустым")
    }

    func testFallBackToLegacyPolicyUsesCleartextCopyOnUnreadableContainer() throws {
        XCTAssertTrue(makeStore().save(sample))
        let legacy = Payload(title: "из legacy", count: 1)
        defaults.set(try JSONEncoder().encode(legacy), forKey: legacyKey)

        let otherKey = SecureStore(directory: directory, keyProvider: InMemorySecureStoreKeyProvider())
        let subject = SecureCodableStore<Payload>(
            name: "payload",
            legacyKey: legacyKey,
            store: otherKey,
            defaults: defaults,
            policy: .fallBackToLegacy
        )
        XCTAssertEqual(subject.load(), legacy, "невосстановимые данные должны браться из legacy")
    }

    func testClearRemovesBothContainerAndLegacyKey() throws {
        XCTAssertTrue(makeStore().save(sample))
        defaults.set(try JSONEncoder().encode(sample), forKey: legacyKey)

        makeStore().clear()

        XCTAssertFalse(store.exists("payload"))
        XCTAssertNil(defaults.data(forKey: legacyKey))
    }
}
