import XCTest
@testable import OWAWidget

/// The MCP switches decide whether any program may read the calendar, so they must not be
/// writable from outside the app: these tests pin that they live in `SecureStore`, that the old
/// `UserDefaults` keys are carried over once and then ignored.
final class MCPSettingsStoreTests: XCTestCase {
    private var directory: URL!
    private var secureStore: SecureStore!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("mcp-settings-tests-\(UUID().uuidString)", isDirectory: true)
        secureStore = SecureStore(directory: directory, keyProvider: InMemorySecureStoreKeyProvider())
        suiteName = "mcp.settings.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try super.tearDownWithError()
    }

    private func makeStore() -> MCPSettingsStore.Store {
        MCPSettingsStore.makeStore(secureStore: secureStore, defaults: defaults)
    }

    private func load() -> MCPSettings {
        MCPSettingsStore.load(from: makeStore(), defaults: defaults)
    }

    func testFreshInstallIsOffAndAsks() {
        let settings = load()
        XCTAssertFalse(settings.serverEnabled)
        XCTAssertFalse(settings.createMeetings)
        XCTAssertTrue(settings.askNewClients)
    }

    func testLegacyValuesAreMigratedAndRemoved() {
        defaults.set(true, forKey: MCPSettingsStore.legacyEnabledKey)
        defaults.set(true, forKey: MCPSettingsStore.legacyCreateMeetingsKey)
        defaults.set(false, forKey: MCPSettingsStore.legacyAskNewClientsKey)

        let settings = load()

        XCTAssertEqual(settings, MCPSettings(serverEnabled: true, createMeetings: true, askNewClients: false))
        for key in MCPSettingsStore.legacyDefaultsKeys {
            XCTAssertNil(defaults.object(forKey: key), key)
        }
        XCTAssertEqual(makeStore().load(), settings)
    }

    /// The attack this store exists for: `defaults write … mcpServerEnabled -bool true` plus
    /// `mcpAskNewClients -bool false`, then wait for the next launch.
    func testDefaultsWrittenAfterMigrationAreIgnored() {
        XCTAssertFalse(load().serverEnabled)

        defaults.set(true, forKey: MCPSettingsStore.legacyEnabledKey)
        defaults.set(false, forKey: MCPSettingsStore.legacyAskNewClientsKey)

        let settings = load()
        XCTAssertFalse(settings.serverEnabled)
        XCTAssertTrue(settings.askNewClients)
        XCTAssertNil(defaults.object(forKey: MCPSettingsStore.legacyEnabledKey))
    }

    func testSavedSwitchesRoundTrip() {
        let saved = MCPSettings(serverEnabled: true, createMeetings: false, askNewClients: true)
        XCTAssertTrue(makeStore().save(saved))
        XCTAssertEqual(load(), saved)
    }

    func testUnreadableStoreFallsBackToOffNotToLegacy() throws {
        XCTAssertTrue(makeStore().save(MCPSettings(serverEnabled: true)))
        // Another key cannot open the container: the store is there but unreadable.
        let foreign = SecureStore(directory: directory, keyProvider: InMemorySecureStoreKeyProvider())
        defaults.set(true, forKey: MCPSettingsStore.legacyEnabledKey)

        let settings = MCPSettingsStore.load(
            from: MCPSettingsStore.makeStore(secureStore: foreign, defaults: defaults),
            defaults: defaults
        )
        XCTAssertFalse(settings.serverEnabled)
    }

    func testSnapshotReflectsUpdates() {
        let snapshot = MCPSettingsSnapshot(MCPSettings())
        XCTAssertFalse(snapshot.current.serverEnabled)
        snapshot.update(MCPSettings(serverEnabled: true))
        XCTAssertTrue(snapshot.current.serverEnabled)
    }
}
