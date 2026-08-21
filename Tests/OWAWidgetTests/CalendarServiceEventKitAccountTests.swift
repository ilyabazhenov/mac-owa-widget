import CryptoKit
import XCTest
@testable import OWAWidget

/// How the service handles an account that has no password.
///
/// Before EventKit existed, `rebuildProviders()` dropped any account without a Keychain entry, and
/// `addAccount` demanded one. A calendar the system already syncs holds no secret at all, so both
/// had to learn the difference.
@MainActor
final class CalendarServiceEventKitAccountTests: XCTestCase {
    private var directory: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!
    /// One key for the whole test: a fresh `InMemorySecureStoreKeyProvider()` generates a random
    /// one, so re-reading the store with a new provider would fail to decrypt rather than tell us
    /// anything about the account.
    private var encryptionKey: SymmetricKey!

    private actor UnusedEventKitStore: EventKitStoring {
        func authorizationStatus() -> EventKitAccessStatus { .denied }
        func requestAccess() -> EventKitAccessStatus { .denied }
        func calendars() -> [EventKitCalendarSnapshot] { [] }
        func events(
            from start: Date,
            to end: Date,
            calendarIdentifiers: [String]
        ) -> [EventKitEventSnapshot] { [] }
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("eventkit-account-tests-\(UUID().uuidString)", isDirectory: true)
        suiteName = "eventkit.account.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        encryptionKey = SymmetricKey(size: .bits256)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try super.tearDownWithError()
    }

    private func eventKitAccount() -> CalendarAccount {
        CalendarAccount(
            displayName: "Google",
            serverURL: "",
            email: "",
            accountType: .eventKit,
            calendarIdentifiers: ["cal-1"]
        )
    }

    private func owaAccount() -> CalendarAccount {
        CalendarAccount(
            displayName: "Работа",
            serverURL: "https://mail.example.com",
            email: "DOMAIN\\user"
        )
    }

    private func makeStore() -> SecureCodableStore<[CalendarAccount]> {
        let secureStore = SecureStore(
            directory: directory,
            keyProvider: InMemorySecureStoreKeyProvider(key: encryptionKey)
        )
        return CalendarService.makeAccountStore(secureStore: secureStore, defaults: defaults)
    }

    private func makeService(seeded: [CalendarAccount] = []) -> CalendarService {
        let store = makeStore()
        if !seeded.isEmpty {
            XCTAssertTrue(store.save(seeded))
        }
        return CalendarService(
            providers: [],
            eventCacheStore: EmptyEventCacheStore(),
            accountStore: store,
            notificationService: SilentNotificationService(),
            customMeetingReminders: SilentMeetingReminderController(),
            eventKitStore: UnusedEventKitStore(),
            loadPersistedAccounts: true,
            startBackgroundTasks: false
        )
    }

    /// The Keychain is never touched on this path — there is no password to save, and asking for
    /// one would raise the system keychain dialog for nothing.
    func testAddsAccountWithoutAPassword() throws {
        let service = makeService()

        try service.addAccount(eventKitAccount(), password: nil)

        XCTAssertEqual(service.accounts.count, 1)
        XCTAssertEqual(service.accounts.first?.accountType, .eventKit)
        XCTAssertEqual(service.accounts.first?.calendarIdentifiers, ["cal-1"])
    }

    func testPasswordlessAccountSurvivesAReload() throws {
        let service = makeService()
        try service.addAccount(eventKitAccount(), password: nil)

        let reloaded = makeService()

        XCTAssertEqual(reloaded.accounts.count, 1)
        XCTAssertEqual(reloaded.accounts.first?.accountType, .eventKit)
    }

    /// A read-only account sorting first must not claim the create-meeting window.
    func testCreateMeetingPicksTheAccountThatCanActuallyCreate() {
        let service = makeService(seeded: [eventKitAccount(), owaAccount()])

        XCTAssertTrue(service.supportsMeetingCreation)
        XCTAssertEqual(service.meetingCreationAccount?.accountType, .owa)
    }

    func testCreateMeetingIsUnavailableWithOnlyReadOnlyAccounts() {
        let service = makeService(seeded: [eventKitAccount()])

        XCTAssertFalse(service.supportsMeetingCreation)
        XCTAssertNil(service.meetingCreationAccount)
    }
}
