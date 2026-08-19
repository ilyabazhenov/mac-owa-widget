import XCTest
@testable import OWAWidget

/// Approvals for hosts that may receive an account's credentials beyond its own server.
///
/// The interesting cases are the ones where an approval must *not* apply: a different server, a
/// differently-spelled host, or anything nobody said yes to.
final class TrustedLoginHostStoreTests: XCTestCase {
    private var directory: URL!
    private var secureStore: SecureStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("trustedloginhosts-tests-\(UUID().uuidString)", isDirectory: true)
        secureStore = SecureStore(directory: directory, keyProvider: InMemorySecureStoreKeyProvider())
        TrustedLoginHostStore.replaceStoreForTesting(
            TrustedLoginHostStore.makeStore(
                secureStore: secureStore,
                defaults: UserDefaults(suiteName: "trustedloginhosts.tests.\(UUID().uuidString)")!
            )
        )
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try super.tearDownWithError()
    }

    private var key: String { TrustedLoginHostStore.key(configuredHost: "mail.example.com") }

    func testNothingIsApprovedByDefault() {
        XCTAssertFalse(TrustedLoginHostStore.isApproved(loginHost: "adfs.example.com", forKey: key))
        XCTAssertTrue(TrustedLoginHostStore.approvedHosts(forKey: key).isEmpty)
    }

    func testApprovedHostIsRemembered() {
        TrustedLoginHostStore.approve(loginHost: "adfs.example.com", forKey: key)
        XCTAssertTrue(TrustedLoginHostStore.isApproved(loginHost: "adfs.example.com", forKey: key))
    }

    func testApprovalSurvivesARoundTripThroughTheContainer() {
        TrustedLoginHostStore.approve(loginHost: "adfs.example.com", forKey: key)
        // Drop the in-memory cache by rebuilding the store over the same encrypted directory.
        TrustedLoginHostStore.replaceStoreForTesting(
            TrustedLoginHostStore.makeStore(
                secureStore: secureStore,
                defaults: UserDefaults(suiteName: "trustedloginhosts.tests.\(UUID().uuidString)")!
            )
        )
        XCTAssertTrue(TrustedLoginHostStore.isApproved(loginHost: "adfs.example.com", forKey: key))
    }

    func testApprovalIsCaseAndRootLabelInsensitive() {
        TrustedLoginHostStore.approve(loginHost: "ADFS.Example.com.", forKey: key)
        XCTAssertTrue(TrustedLoginHostStore.isApproved(loginHost: "adfs.example.com", forKey: key))
        XCTAssertTrue(TrustedLoginHostStore.isApproved(loginHost: "ADFS.EXAMPLE.COM", forKey: key))
    }

    /// Approving an identity provider for one Exchange server says nothing about another one.
    func testApprovalIsScopedToTheConfiguredServer() {
        TrustedLoginHostStore.approve(loginHost: "adfs.example.com", forKey: key)
        let otherServer = TrustedLoginHostStore.key(configuredHost: "mail.other.example")
        XCTAssertFalse(TrustedLoginHostStore.isApproved(loginHost: "adfs.example.com", forKey: otherServer))
    }

    func testLookalikeHostIsNotApproved() {
        TrustedLoginHostStore.approve(loginHost: "adfs.example.com", forKey: key)
        XCTAssertFalse(TrustedLoginHostStore.isApproved(loginHost: "adfs.example.com.evil.test", forKey: key))
        XCTAssertFalse(TrustedLoginHostStore.isApproved(loginHost: "evil.test", forKey: key))
    }

    func testEmptyHostIsNeverApproved() {
        TrustedLoginHostStore.approve(loginHost: "", forKey: key)
        XCTAssertFalse(TrustedLoginHostStore.isApproved(loginHost: "", forKey: key))
        XCTAssertTrue(TrustedLoginHostStore.approvedHosts(forKey: key).isEmpty)
    }

    func testRevokeDropsEveryApprovalForTheServer() {
        TrustedLoginHostStore.approve(loginHost: "adfs.example.com", forKey: key)
        TrustedLoginHostStore.approve(loginHost: "sso.example.com", forKey: key)
        TrustedLoginHostStore.revoke(forKey: key)
        XCTAssertTrue(TrustedLoginHostStore.approvedHosts(forKey: key).isEmpty)
        XCTAssertFalse(TrustedLoginHostStore.isApproved(loginHost: "adfs.example.com", forKey: key))
    }

    // MARK: - Sync status

    /// The scheduler must treat this like the certificate block: suspended until the user answers,
    /// not retried on every tick.
    func testApprovalRequiredBlocksSync() {
        XCTAssertTrue(blockedStatus.blocksSync)
        XCTAssertTrue(blockedStatus.isLoginHostApprovalRequired)
        XCTAssertFalse(blockedStatus.isAuthenticationRequired)
        XCTAssertFalse(blockedStatus.isCertificateTrustRequired)
    }

    /// A suspended sync has to be visible. This state used to render as an ordinary empty day
    /// because the popover enumerated blocking statuses by hand and did not know about this one.
    func testApprovalRequiredShowsTheErrorStateInThePopover() {
        XCTAssertTrue(SyncPresentationPolicy.shouldShowErrorState(syncStatus: blockedStatus, eventsCount: 0))
        // Cached events still win: something useful on screen beats an error panel.
        XCTAssertFalse(SyncPresentationPolicy.shouldShowErrorState(syncStatus: blockedStatus, eventsCount: 3))
    }

    /// Nothing is wrong with the stored password, so the wrong-password breaker must stay out of
    /// it — latching would ask the user to retype a credential that is perfectly correct.
    func testApprovalRequiredIsNotAnAuthError() {
        let error = OWAError.loginHostApprovalRequired(
            UnapprovedLoginHost(
                configuredHost: "mail.example.com",
                loginHost: "adfs.evil.test",
                redirectChain: []
            )
        )
        XCTAssertFalse(OWAError.isAuthError(error))
        XCTAssertFalse(OWAError.isDefinitiveAuthRejection(error))
        XCTAssertFalse(OWAError.isSessionStaleHTTPError(error))
        XCTAssertEqual(OWAError.loginHostApprovalInfo(from: error)?.loginHost, "adfs.evil.test")
    }

    private var blockedStatus: SyncStatus {
        .loginHostApprovalRequired(configuredHost: "mail.example.com", loginHost: "adfs.evil.test")
    }
}
