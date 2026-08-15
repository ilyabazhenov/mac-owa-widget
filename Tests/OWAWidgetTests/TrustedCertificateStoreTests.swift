import XCTest
@testable import OWAWidget

/// The legacy Keychain drain is disabled under test on purpose (it deletes real login-keychain
/// items), so these tests cover the encrypted store and the pinning logic on top of it.
final class TrustedCertificateStoreTests: XCTestCase {
    private var directory: URL!
    private var secureStore: SecureStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("trustedcerts-tests-\(UUID().uuidString)", isDirectory: true)
        secureStore = SecureStore(directory: directory, keyProvider: InMemorySecureStoreKeyProvider())
        TrustedCertificateStore.replaceStoreForTesting(
            TrustedCertificateStore.makeStore(secureStore: secureStore, defaults: makeDefaults())
        )
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try super.tearDownWithError()
    }

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "trustedcerts.tests.\(UUID().uuidString)")!
    }

    func testKeyNormalizesHostCase() {
        XCTAssertEqual(TrustedCertificateStore.key(host: "Mail.Example.COM", port: 443), "mail.example.com:443")
    }

    func testUnknownHostTrustsNothing() {
        XCTAssertTrue(TrustedCertificateStore.trustedFingerprints(forKey: "mail.example.com:443").isEmpty)
        XCTAssertFalse(TrustedCertificateStore.isTrusted(fingerprint: "abc", forKey: "mail.example.com:443"))
    }

    func testTrustedFingerprintIsRemembered() {
        let key = TrustedCertificateStore.key(host: "mail.example.com", port: 443)
        TrustedCertificateStore.trust(fingerprint: "aa11", forKey: key)

        XCTAssertTrue(TrustedCertificateStore.isTrusted(fingerprint: "aa11", forKey: key))
        XCTAssertFalse(TrustedCertificateStore.isTrusted(fingerprint: "bb22", forKey: key))
    }

    func testSeveralFingerprintsPerHostCoexist() {
        let key = TrustedCertificateStore.key(host: "mail.example.com", port: 443)
        TrustedCertificateStore.trust(fingerprint: "aa11", forKey: key)
        TrustedCertificateStore.trust(fingerprint: "bb22", forKey: key)

        XCTAssertEqual(TrustedCertificateStore.trustedFingerprints(forKey: key), ["aa11", "bb22"])
    }

    func testHostsAreIsolatedFromEachOther() {
        let a = TrustedCertificateStore.key(host: "a.example.com", port: 443)
        let b = TrustedCertificateStore.key(host: "b.example.com", port: 443)
        TrustedCertificateStore.trust(fingerprint: "aa11", forKey: a)

        XCTAssertFalse(TrustedCertificateStore.isTrusted(fingerprint: "aa11", forKey: b))
    }

    func testUntrustClearsOnlyTheGivenHost() {
        let a = TrustedCertificateStore.key(host: "a.example.com", port: 443)
        let b = TrustedCertificateStore.key(host: "b.example.com", port: 443)
        TrustedCertificateStore.trust(fingerprint: "aa11", forKey: a)
        TrustedCertificateStore.trust(fingerprint: "bb22", forKey: b)

        TrustedCertificateStore.untrust(forKey: a)

        XCTAssertTrue(TrustedCertificateStore.trustedFingerprints(forKey: a).isEmpty)
        XCTAssertTrue(TrustedCertificateStore.isTrusted(fingerprint: "bb22", forKey: b))
    }

    func testTrustSurvivesARestartOfTheStore() {
        let key = TrustedCertificateStore.key(host: "mail.example.com", port: 443)
        TrustedCertificateStore.trust(fingerprint: "aa11", forKey: key)

        // Same directory and key, fresh instance and cache — as after an app relaunch.
        TrustedCertificateStore.replaceStoreForTesting(
            TrustedCertificateStore.makeStore(secureStore: secureStore, defaults: makeDefaults())
        )
        XCTAssertTrue(TrustedCertificateStore.isTrusted(fingerprint: "aa11", forKey: key))
    }

    // MARK: - Behaviour when the encrypted store cannot be written

    /// The Keychain drain is disabled under test, so the ordering it depends on — persist first,
    /// delete the originals only afterwards — is enforced by structure and reviewed by eye. What
    /// is testable is the half that ordering leans on: a failed write must leave the session
    /// working from memory rather than reporting the pin as gone.
    func testTrustSurvivesInMemoryWhenTheStoreCannotBeWritten() throws {
        let brokenDirectory = directory.appendingPathComponent("broken", isDirectory: true)
        let broken = SecureStore(directory: brokenDirectory, keyProvider: UnavailableSecureStoreKeyProvider())
        TrustedCertificateStore.replaceStoreForTesting(
            TrustedCertificateStore.makeStore(secureStore: broken, defaults: makeDefaults())
        )

        let key = TrustedCertificateStore.key(host: "mail.example.com", port: 443)
        TrustedCertificateStore.trust(fingerprint: "aa11", forKey: key)

        XCTAssertTrue(
            TrustedCertificateStore.isTrusted(fingerprint: "aa11", forKey: key),
            "в пределах сессии пин должен работать даже без возможности записи"
        )
        XCTAssertFalse(broken.exists(TrustedCertificateStore.storageName))
    }

    // MARK: - Legacy payload parsing

    func testParseFingerprintsSplitsNewlineSeparatedPayload() {
        XCTAssertEqual(TrustedCertificateStore.parseFingerprints("aa11\nbb22"), ["aa11", "bb22"])
    }

    func testParseFingerprintsIgnoresBlankLines() {
        XCTAssertEqual(TrustedCertificateStore.parseFingerprints("\naa11\n\n\n"), ["aa11"])
    }

    func testParseFingerprintsOfEmptyPayloadIsEmpty() {
        // An empty result must never be mistaken for a successful read: the drain deletes the
        // Keychain item only after `legacyPayload` returned something, not on an empty parse.
        XCTAssertTrue(TrustedCertificateStore.parseFingerprints("").isEmpty)
        XCTAssertTrue(TrustedCertificateStore.parseFingerprints("\n\n").isEmpty)
    }

    func testFingerprintsAreNotStoredInCleartext() throws {
        let key = TrustedCertificateStore.key(host: "mail.example.com", port: 443)
        TrustedCertificateStore.trust(fingerprint: "deadbeef", forKey: key)

        let raw = try Data(contentsOf: secureStore.url(for: TrustedCertificateStore.storageName))
        XCTAssertNil(raw.range(of: Data("deadbeef".utf8)))
        XCTAssertNil(raw.range(of: Data("mail.example.com".utf8)))
    }
}
