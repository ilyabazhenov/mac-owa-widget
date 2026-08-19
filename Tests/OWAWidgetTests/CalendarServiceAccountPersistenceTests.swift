import XCTest
@testable import OWAWidget

/// Behaviour when the encrypted account store cannot be written — the master key lives in the
/// Keychain and the user can decline access to it, so this is a reachable state rather than a
/// theoretical one. The in-memory account list must never claim something the disk does not.
///
/// Accounts are seeded through the cleartext legacy key, which also exercises the
/// `.fallBackToLegacy` policy: with the key unavailable the encrypted read fails, the cleartext
/// copy is preserved, and the service still comes up with its accounts.
@MainActor
final class CalendarServiceAccountPersistenceTests: XCTestCase {
    private var directory: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    private let legacyAccountsKey = "calendarAccounts"

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("account-persistence-tests-\(UUID().uuidString)", isDirectory: true)
        suiteName = "account.persistence.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try super.tearDownWithError()
    }

    private func makeAccount() -> CalendarAccount {
        CalendarAccount(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            displayName: "Работа",
            serverURL: "https://mail.example.com",
            email: "user@example.com"
        )
    }

    private func makeService(keyAvailable: Bool) -> CalendarService {
        let secureStore = SecureStore(
            directory: directory,
            keyProvider: keyAvailable
                ? InMemorySecureStoreKeyProvider()
                : UnavailableSecureStoreKeyProvider()
        )
        return CalendarService(
            providers: [],
            eventCacheStore: EmptyEventCacheStore(),
            accountStore: CalendarService.makeAccountStore(secureStore: secureStore, defaults: defaults),
            notificationService: SilentNotificationService(),
            customMeetingReminders: SilentMeetingReminderController(),
            loadPersistedAccounts: true,
            startBackgroundTasks: false
        )
    }

    private func seedLegacyAccount() throws {
        defaults.set(try JSONEncoder().encode([makeAccount()]), forKey: legacyAccountsKey)
    }

    private func seedEncryptedAccount() {
        let writable = SecureStore(directory: directory, keyProvider: InMemorySecureStoreKeyProvider())
        let store = CalendarService.makeAccountStore(secureStore: writable, defaults: defaults)
        XCTAssertTrue(store.save([makeAccount()]))
    }

    // MARK: - Distinguishing "no accounts" from "cannot read accounts"

    // The popover shows an invitation to add an account when `accounts` is empty. If it did that
    // for a store it merely failed to read, the obvious next step — adding the account again —
    // would persist a one-element list over the accounts still on disk. So the two states have to
    // stay distinguishable at the service level.

    func testAccountStoreUnreadableIsFalseOnCleanInstall() {
        let service = makeService(keyAvailable: true)

        XCTAssertTrue(service.accounts.isEmpty)
        XCTAssertFalse(service.accountStoreUnreadable, "чистая установка — не ошибка чтения")
    }

    func testAccountStoreUnreadableIsTrueWhenContainerCannotBeRead() {
        seedEncryptedAccount()

        let service = makeService(keyAvailable: false)

        XCTAssertTrue(service.accounts.isEmpty, "прочитать нечем")
        XCTAssertTrue(
            service.accountStoreUnreadable,
            "аккаунты на диске есть — UI не должен предлагать завести их заново"
        )
    }

    func testAccountStoreUnreadableIsFalseWhenLegacyCopyRescuesAccounts() throws {
        seedEncryptedAccount()
        try seedLegacyAccount()

        let service = makeService(keyAvailable: false)

        XCTAssertEqual(service.accounts.map(\.email), ["user@example.com"])
        XCTAssertFalse(service.accountStoreUnreadable, "аккаунты доехали — предупреждать не о чем")
    }

    // MARK: - Reading

    func testAccountsStillLoadFromLegacyCopyWhenKeyIsUnavailable() throws {
        try seedLegacyAccount()
        let service = makeService(keyAvailable: false)

        XCTAssertEqual(service.accounts.map(\.email), ["user@example.com"])
        XCTAssertNotNil(
            defaults.data(forKey: legacyAccountsKey),
            "открытую копию нельзя удалять, пока зашифрованная не записана"
        )
    }

    // MARK: - Writing

    func testUpdateAccountRollsBackWhenPersistenceFails() throws {
        try seedLegacyAccount()
        let service = makeService(keyAvailable: false)

        var updated = try XCTUnwrap(service.accounts.first)
        updated.displayName = "Переименованный"

        XCTAssertThrowsError(try service.updateAccount(updated, newPassword: nil)) { error in
            XCTAssertEqual(error as? CalendarServiceError, .accountPersistenceFailed)
        }
        XCTAssertEqual(
            service.accounts.first?.displayName,
            "Работа",
            "при неудачной записи список должен вернуться к прежнему состоянию"
        )
    }

    func testUpdateAccountKeepsChangeWhenPersistenceSucceeds() throws {
        try seedLegacyAccount()
        let service = makeService(keyAvailable: true)

        var updated = try XCTUnwrap(service.accounts.first)
        updated.displayName = "Переименованный"

        XCTAssertNoThrow(try service.updateAccount(updated, newPassword: nil))
        XCTAssertEqual(service.accounts.first?.displayName, "Переименованный")
    }

    func testRemoveAccountReportsPersistenceFailure() throws {
        try seedLegacyAccount()
        let service = makeService(keyAvailable: false)
        let account = try XCTUnwrap(service.accounts.first)

        // Deleting a Keychain password that was never created succeeds, so this stays off the
        // real login keychain.
        XCTAssertThrowsError(try service.removeAccount(account)) { error in
            XCTAssertEqual(error as? CalendarServiceError, .accountPersistenceFailed)
        }
    }

    func testSuccessfulUpdateDrainsTheCleartextCopy() throws {
        try seedLegacyAccount()
        let service = makeService(keyAvailable: true)

        var updated = try XCTUnwrap(service.accounts.first)
        updated.displayName = "Переименованный"
        XCTAssertNoThrow(try service.updateAccount(updated, newPassword: nil))

        XCTAssertNil(defaults.data(forKey: legacyAccountsKey), "открытая копия пережила успешную запись")
    }
}

// MARK: - Doubles

private final class EmptyEventCacheStore: EventCacheStoring {
    func load() -> EventCacheSnapshot? { nil }
    func save(events: [CalendarEvent], rangeStart: Date, rangeEnd: Date) {}
    func clear() {}
}

private actor SilentNotificationService: NotificationServicing {
    func setup(localization: NotificationLocalization) {}
    func requestAuthorization() async {}
    func removeAllPendingMeetingNotifications() async {}
    func scheduleNotifications(for events: [CalendarEvent], leadMinutes: Int, localization: NotificationLocalization) async {}
}

@MainActor
private final class SilentMeetingReminderController: CustomMeetingReminderControlling {
    func cancelAll(closeActiveReminder: Bool) {}
    func reschedule(
        events: [CalendarEvent],
        leadMinutes: Int,
        localization: NotificationLocalization,
        sound: MeetingReminderSound
    ) {}
}
