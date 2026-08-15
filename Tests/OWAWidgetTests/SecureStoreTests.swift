import CryptoKit
import XCTest
@testable import OWAWidget

/// Every test here runs against a temporary directory and an in-memory key.
/// Nothing in this file may touch the real Keychain: `swift test` is a required gate for
/// `make release-package`, and a live Keychain item would eventually block packaging behind
/// an authorization dialog after a rebuild changes the ad-hoc code signature.
final class SecureStoreTests: XCTestCase {
    private var directory: URL!
    private var store: SecureStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("securestore-tests-\(UUID().uuidString)", isDirectory: true)
        store = SecureStore(directory: directory, keyProvider: InMemorySecureStoreKeyProvider())
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try super.tearDownWithError()
    }

    // MARK: - Round trip

    func testWriteThenReadReturnsPayload() throws {
        let payload = Data("совещание в 15:00".utf8)
        try store.write(payload, name: "events")
        XCTAssertEqual(try store.read("events"), payload)
    }

    func testReadReturnsNilWhenNothingStored() throws {
        XCTAssertNil(try store.read("events"))
    }

    func testCiphertextDoesNotContainPlaintext() throws {
        let payload = Data("секретная повестка".utf8)
        try store.write(payload, name: "events")
        let onDisk = try Data(contentsOf: store.url(for: "events"))
        XCTAssertFalse(onDisk.range(of: payload) != nil, "полезная нагрузка осталась в открытом виде")
    }

    func testRemoveDeletesContainer() throws {
        try store.write(Data("x".utf8), name: "events")
        XCTAssertTrue(store.exists("events"))
        store.remove("events")
        XCTAssertFalse(store.exists("events"))
        XCTAssertNil(try store.read("events"))
    }

    // MARK: - Authentication

    func testContainerFromAnotherStorageNameIsRejected() throws {
        // Binding the name into the AAD is what stops accounts.enc being swapped for events.enc.
        let container = try store.seal(payload: Data("accounts".utf8), name: "accounts")
        XCTAssertThrowsError(try store.open(container: container, name: "events")) { error in
            XCTAssertEqual(error as? SecureStoreError, .authenticationFailed)
        }
    }

    func testTamperedCiphertextIsRejected() throws {
        try store.write(Data("совещание".utf8), name: "events")
        let fileURL = store.url(for: "events")
        var bytes = try Data(contentsOf: fileURL)
        bytes[bytes.count - 1] ^= 0xFF
        try bytes.write(to: fileURL)

        XCTAssertThrowsError(try store.read("events")) { error in
            XCTAssertEqual(error as? SecureStoreError, .authenticationFailed)
        }
    }

    func testFormatVersionDowngradeIsRejected() throws {
        var container = try store.seal(payload: Data("x".utf8), name: "events")
        container[4] = 0
        XCTAssertThrowsError(try store.open(container: container, name: "events")) { error in
            XCTAssertEqual(error as? SecureStoreError, .unsupportedFormatVersion(0))
        }
    }

    func testUnknownKeyIDIsRejected() throws {
        var container = try store.seal(payload: Data("x".utf8), name: "events")
        container[5] = 9
        XCTAssertThrowsError(try store.open(container: container, name: "events")) { error in
            XCTAssertEqual(error as? SecureStoreError, .unknownKeyID(9))
        }
    }

    func testForeignFileIsRejectedAsNotAContainer() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("just some plain text file".utf8).write(to: store.url(for: "events"))
        XCTAssertThrowsError(try store.read("events")) { error in
            XCTAssertEqual(error as? SecureStoreError, .notAContainer)
        }
    }

    func testTruncatedContainerIsRejected() throws {
        let container = try store.seal(payload: Data("x".utf8), name: "events")
        let truncated = container.prefix(SecureStore.headerLength)
        XCTAssertThrowsError(try store.open(container: Data(truncated), name: "events")) { error in
            XCTAssertEqual(error as? SecureStoreError, .notAContainer)
        }
    }

    func testContainerSealedWithAnotherKeyIsRejected() throws {
        let container = try store.seal(payload: Data("x".utf8), name: "events")
        let other = SecureStore(directory: directory, keyProvider: InMemorySecureStoreKeyProvider())
        XCTAssertThrowsError(try other.open(container: container, name: "events")) { error in
            XCTAssertEqual(error as? SecureStoreError, .authenticationFailed)
        }
    }

    // MARK: - Key availability

    func testUnavailableKeyMakesWriteThrowAndLeavesNoFile() throws {
        let broken = SecureStore(directory: directory, keyProvider: UnavailableSecureStoreKeyProvider())
        XCTAssertFalse(broken.isKeyAvailable)
        XCTAssertThrowsError(try broken.write(Data("x".utf8), name: "events"))
        XCTAssertFalse(broken.exists("events"))
    }

    func testUnavailableKeyMakesReadThrowRatherThanReturnNil() throws {
        try store.write(Data("x".utf8), name: "events")
        let broken = SecureStore(directory: directory, keyProvider: UnavailableSecureStoreKeyProvider())
        // Must be distinguishable from "nothing stored" — callers keep the legacy copy on error.
        XCTAssertThrowsError(try broken.read("events"))
    }

    // MARK: - On-disk protection

    func testContainerAndDirectoryUseRestrictivePermissions() throws {
        try store.write(Data("x".utf8), name: "events")

        let fileAttrs = try FileManager.default.attributesOfItem(atPath: store.url(for: "events").path)
        XCTAssertEqual(fileAttrs[.posixPermissions] as? NSNumber, 0o600)

        let dirAttrs = try FileManager.default.attributesOfItem(atPath: directory.path)
        XCTAssertEqual(dirAttrs[.posixPermissions] as? NSNumber, 0o700)
    }

    func testDefaultDirectoryIsScopedByBundleIdentifier() {
        // Without this scoping a `.dev` build would share store files with the installed app
        // and overwrite its accounts — `UserDefaults` has always kept them apart.
        let path = SecureStore.defaultDirectory().path
        let bundleID = Bundle.main.bundleIdentifier ?? "com.owawidget.MacOwaWidget"
        XCTAssertTrue(path.contains(bundleID), "путь \(path) не разделён по bundle id")
        XCTAssertTrue(path.hasSuffix("store"))
    }
}
