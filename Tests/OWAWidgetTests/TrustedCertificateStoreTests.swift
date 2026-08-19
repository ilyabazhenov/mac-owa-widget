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

    // MARK: - Summary lines

    private func makeFormatter() -> DateFormatter {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }

    private func lines(_ details: ServerCertificateDetails) -> [String] {
        details.summaryLines(
            subjectLabel: "Issued to:",
            issuerLabel: "Issued by:",
            validUntilLabel: "Valid until:",
            dateFormatter: makeFormatter()
        )
    }

    func testSummaryLinesFollowReadingOrder() {
        let details = ServerCertificateDetails(
            subject: "mail.example.com",
            issuer: "Corp Internal CA",
            notBefore: Date(timeIntervalSince1970: 0),
            notAfter: Date(timeIntervalSince1970: 1_800_000_000)
        )

        XCTAssertEqual(lines(details), [
            "Issued to: mail.example.com",
            "Issued by: Corp Internal CA",
            "Valid until: Jan 15, 2027"
        ])
    }

    func testSummaryLinesSkipFieldsTheCertificateDoesNotCarry() {
        let details = ServerCertificateDetails(
            subject: nil, issuer: "Corp Internal CA", notBefore: nil, notAfter: nil
        )

        // Печатать "Кому выдан:" без значения хуже, чем не печатать: подсказка, ради которой
        // диалог и существует, начинает выглядеть сломанной.
        XCTAssertEqual(lines(details), ["Issued by: Corp Internal CA"])
    }

    func testSummaryLinesOfEmptyDetailsAreEmpty() {
        let details = ServerCertificateDetails(subject: nil, issuer: nil, notBefore: nil, notAfter: nil)

        XCTAssertTrue(details.isEmpty)
        XCTAssertTrue(lines(details).isEmpty)
    }

    // MARK: - Certificate details

    // Self-signed fixture generated with openssl:
    //   CN=mail.example.com, O=Example Corp, valid 2026-08-19 .. 2036-08-16
    // Parsing these fields goes through `SecCertificateCopyValues`, whose shape (dictionaries of
    // {label, value}, dates as seconds since the 2001 reference date) is easy to get subtly wrong
    // and impossible to notice by eye in a dialog.
    private static let sampleCertificateDER =
        "MIIDRTCCAi2gAwIBAgIUFYAMJcvnk9zKPVjxKshOE1OgT/kwDQYJKoZIhvcNAQELBQAwMjEZMBcG" +
        "A1UEAwwQbWFpbC5leGFtcGxlLmNvbTEVMBMGA1UECgwMRXhhbXBsZSBDb3JwMB4XDTI2MDgxOTE3" +
        "NDIzNFoXDTM2MDgxNjE3NDIzNFowMjEZMBcGA1UEAwwQbWFpbC5leGFtcGxlLmNvbTEVMBMGA1UE" +
        "CgwMRXhhbXBsZSBDb3JwMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAp9c42fFSjSXG" +
        "zOjAQiJiyMEaDU0mnVZSxIHCszpwC5ySkGo9AGQsd/U92Bz/tgUksGZbjq76k6uqfie3/CsPM6su" +
        "/OiJtaZzZzdzSe960lV5A0WYgHebOmUvW0BKedDSS+J+ElMgYNKD0EDzGOgYL1PSPA6Zpv0ek+nf" +
        "T5s2b0aaQqDxu1o8d+xl77e5LzAe5PJJ+gfih6oqYr35CG5USJv6YyJfgsxnL4qmbZCPP0FXwvIJ" +
        "wlhU7VOZjTO4RfzZUN/7A5ryNkk58AkmklfPFBfV3Bp6+Nfb60FG3rMKfU1N7VfkLaNvTc4naucq" +
        "AKvZ3IBSpbwTPCMj6MyXfmCdCwIDAQABo1MwUTAdBgNVHQ4EFgQUw6O3vQHA3l6BVt46azoa8Bw7" +
        "pxEwHwYDVR0jBBgwFoAUw6O3vQHA3l6BVt46azoa8Bw7pxEwDwYDVR0TAQH/BAUwAwEB/zANBgkq" +
        "hkiG9w0BAQsFAAOCAQEACofPFmaad+l46OWKDrc7W5VZkX0bWf8wkjxFBBmmfmlbGGKhTDdQopUl" +
        "IfXJqlCAwc/1tS9xcqJnPjwfApmFkxKS+gh0rLZQCpuKwZMMJ+m4fmkUe+Zb0Cx+3JaPkweEodrc" +
        "Q8PpW8dxnG6p5bY1dyATgew1W7aNhw0VcLiE3e/7elVp7DuzYeyZHdk7W3gnRo4oJIP7Dv0lAO4M" +
        "988GkgLpSa097QlP7SLly8znOcsRoQzMGrM1kBO5dcdhQqQw2ObQoPcraGNTROYLRHNVtQkEPBUx" +
        "Q5Ek7WOK6y5XsEMlobi1WC44mKo5JTeJxgu3nIXRuZObJpU3DB+iSDiyLA=="

    private func makeSampleCertificate() throws -> SecCertificate {
        let data = try XCTUnwrap(Data(base64Encoded: Self.sampleCertificateDER))
        return try XCTUnwrap(SecCertificateCreateWithData(nil, data as CFData))
    }

    func testDetailsReadSubjectIssuerAndValidity() throws {
        let details = TrustedCertificateStore.details(of: try makeSampleCertificate())

        XCTAssertEqual(details.subject, "mail.example.com")
        XCTAssertEqual(details.issuer, "mail.example.com")
        let notBefore = try XCTUnwrap(details.notBefore)
        let notAfter = try XCTUnwrap(details.notAfter)
        XCTAssertLessThan(notBefore, notAfter)
        // Ровно десять лет по openssl -days 3650.
        XCTAssertEqual(notAfter.timeIntervalSince(notBefore), 3650 * 24 * 3600, accuracy: 3600)
        XCTAssertFalse(details.isEmpty)
    }

    // MARK: - Replacing a pin

    func testReplaceDropsThePreviousFingerprint() {
        let key = TrustedCertificateStore.key(host: "mail.example.com", port: 443)
        TrustedCertificateStore.trust(fingerprint: "aa11", forKey: key)
        TrustedCertificateStore.trust(fingerprint: "bb22", forKey: key)

        TrustedCertificateStore.replace(fingerprint: "cc33", forKey: key)

        XCTAssertEqual(TrustedCertificateStore.trustedFingerprints(forKey: key), ["cc33"])
        XCTAssertFalse(
            TrustedCertificateStore.isTrusted(fingerprint: "aa11", forKey: key),
            "прежний сертификат обязан перестать быть доверенным"
        )
    }

    func testReplaceLeavesOtherHostsAlone() {
        let a = TrustedCertificateStore.key(host: "a.example.com", port: 443)
        let b = TrustedCertificateStore.key(host: "b.example.com", port: 443)
        TrustedCertificateStore.trust(fingerprint: "aa11", forKey: a)
        TrustedCertificateStore.trust(fingerprint: "bb22", forKey: b)

        TrustedCertificateStore.replace(fingerprint: "cc33", forKey: a)

        XCTAssertEqual(TrustedCertificateStore.trustedFingerprints(forKey: b), ["bb22"])
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
