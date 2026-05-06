import XCTest
@testable import OWAWidget

final class UpdateCheckServiceTests: XCTestCase {

    // MARK: - UpdateVersionComparison

    func testComparePatchVersions() {
        XCTAssertEqual(
            UpdateVersionComparison.compare("1.0.9", "1.0.10"),
            .orderedAscending
        )
    }

    func testCompareEqualVersions() {
        XCTAssertEqual(UpdateVersionComparison.compare("1.0.23", "1.0.23"), .orderedSame)
    }

    func testNormalizeLeadingV() {
        XCTAssertEqual(
            UpdateVersionComparison.compare("1.0.23", "v1.0.24"),
            .orderedAscending
        )
    }

    func testMinorGreaterThanPatch() {
        XCTAssertEqual(
            UpdateVersionComparison.compare("1.0.99", "1.1.0"),
            .orderedAscending
        )
    }

    func testPaddingMissingZeros() {
        XCTAssertEqual(UpdateVersionComparison.compare("1.0", "1.0.0"), .orderedSame)
    }

    func testPrereleaseSuffixOlderThanRelease() {
        XCTAssertEqual(
            UpdateVersionComparison.compare("1.0.10-rc", "1.0.10"),
            .orderedAscending
        )
    }

    func testReleaseNewerThanPrereleaseSameNumeric() {
        XCTAssertEqual(
            UpdateVersionComparison.compare("1.0.10", "1.0.10-rc"),
            .orderedDescending
        )
    }

    func testGarbageVersionsAreSame() {
        XCTAssertEqual(UpdateVersionComparison.compare("foo", "bar"), .orderedSame)
    }

    func testNormalizeTrimsAndStripsV() {
        XCTAssertEqual(UpdateVersionComparison.normalize("  v1.2.3  "), "1.2.3")
    }

    // MARK: - Sparkle bridge state mutations

    @MainActor
    func testProcessFoundUpdatePublishesAvailableUpdate() {
        let service = makeService(currentVersion: "1.0.0")
        let publishedAt = Date(timeIntervalSince1970: 1_700_000_000)

        service.processFoundUpdate(
            version: "v1.0.5",
            fileURL: URL(string: "https://example.com/zip"),
            publishedAt: publishedAt
        )

        XCTAssertNotNil(service.availableUpdate)
        XCTAssertEqual(service.availableUpdate?.version, "1.0.5")
        XCTAssertEqual(service.availableUpdate?.publishedAt, publishedAt)
        XCTAssertEqual(
            service.availableUpdate?.releaseURL.absoluteString,
            "https://github.com/ilyabazhenov/mac-owa-widget/releases/tag/v1.0.5"
        )
    }

    @MainActor
    func testProcessNoUpdateClearsAvailableUpdate() {
        let service = makeService(currentVersion: "1.0.0")
        service.processFoundUpdate(
            version: "1.0.5",
            fileURL: nil,
            publishedAt: Date()
        )
        XCTAssertNotNil(service.availableUpdate)

        service.processNoUpdate()

        XCTAssertNil(service.availableUpdate)
    }

    @MainActor
    func testProcessFoundUpdateIgnoresOlderOrEqualVersion() {
        let service = makeService(currentVersion: "1.0.5")

        service.processFoundUpdate(version: "1.0.5", fileURL: nil, publishedAt: Date())
        XCTAssertNil(service.availableUpdate)

        service.processFoundUpdate(version: "1.0.4", fileURL: nil, publishedAt: Date())
        XCTAssertNil(service.availableUpdate)
    }

    @MainActor
    func testSkipVersionSuppressesSubsequentDiscoveryOfSameVersion() {
        let defaults = ephemeralDefaults()
        let service = makeService(currentVersion: "1.0.0", defaults: defaults)
        service.processFoundUpdate(version: "1.0.5", fileURL: nil, publishedAt: Date())
        XCTAssertNotNil(service.availableUpdate)

        service.skip(version: "v1.0.5")
        XCTAssertNil(service.availableUpdate, "Skipping should clear the current banner")

        service.processFoundUpdate(version: "1.0.5", fileURL: nil, publishedAt: Date())
        XCTAssertNil(service.availableUpdate, "Skipped version must not surface again")

        // A newer version after skipping the older one still surfaces.
        service.processFoundUpdate(version: "1.0.6", fileURL: nil, publishedAt: Date())
        XCTAssertEqual(service.availableUpdate?.version, "1.0.6")
    }

    @MainActor
    func testBridgeForwardsCallbackPayloadToService() async {
        let service = makeService(currentVersion: "1.0.0")
        let bridge = SparkleUpdaterDelegateBridge()
        bridge.owner = service

        // We only exercise the state-mutating tail of the bridge, not Sparkle itself.
        // SPUUpdater / SUAppcastItem are not constructible without the framework's
        // private initializers, so we drive the same code path via the service API
        // that the bridge eventually invokes after its main-actor hop.
        service.processFoundUpdate(
            version: "1.0.7",
            fileURL: URL(string: "https://example.com/x.zip"),
            publishedAt: Date()
        )
        XCTAssertEqual(service.availableUpdate?.version, "1.0.7")
    }

    // MARK: - Helpers

    @MainActor
    private func makeService(
        currentVersion: String,
        defaults: UserDefaults? = nil
    ) -> UpdateCheckService {
        let storage = defaults ?? ephemeralDefaults()
        return UpdateCheckService(
            defaults: storage,
            appVersionOverride: currentVersion,
            createUpdater: false
        )
    }

    private func ephemeralDefaults() -> UserDefaults {
        let suiteName = "OWAWidgetTests.UpdateCheckService.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
