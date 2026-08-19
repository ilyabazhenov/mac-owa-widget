import XCTest
@testable import OWAWidget

@MainActor
final class SettingsViewModelTests: XCTestCase {
    private enum Baseline {
        static let syncInterval: TimeInterval = 300
        static let notificationLeadMinutes = 10
        static let sound = MeetingReminderSound.glass
        static let screen = NotificationScreenPolicy.active
        static let menuBar = MenuBarDisplayMode.countdown
    }

    override func setUp() {
        super.setUp()
        Self.removeTrackedPreferenceKeys()
        Self.applyBaselineUserDefaults()
    }

    override func tearDown() {
        Self.removeTrackedPreferenceKeys()
        super.tearDown()
    }

    func testSavePreferencesPersistsDimPastMeetingsOnTimelineToService() {
        let (service, vm, _) = makeSUT()

        XCTAssertTrue(vm.dimPastMeetingsOnTimeline)
        XCTAssertTrue(service.dimPastMeetingsOnTimeline)

        vm.dimPastMeetingsOnTimeline = false
        XCTAssertTrue(vm.hasUnsavedChanges)
        vm.savePreferences()

        XCTAssertFalse(service.dimPastMeetingsOnTimeline)
        XCTAssertFalse(vm.hasUnsavedChanges)
    }

    func testSavePreferencesPersistsMenuBarDisplayModeToService() {
        let (service, vm, _) = makeSUT()

        XCTAssertFalse(vm.hasUnsavedChanges)
        vm.menuBarDisplayMode = .status
        XCTAssertTrue(vm.hasUnsavedChanges)
        vm.savePreferences()

        XCTAssertEqual(service.menuBarDisplayMode, .status)
        XCTAssertFalse(vm.hasUnsavedChanges)
    }

    func testChangingPopoverSizePresetMarksHasUnsavedChanges() {
        let (_, vm, _) = makeSUT()
        XCTAssertEqual(vm.popoverSizePreset, .compact)
        XCTAssertFalse(vm.hasUnsavedChanges)

        vm.popoverSizePreset = .large
        XCTAssertTrue(vm.hasUnsavedChanges)
    }

    func testRevertingPopoverSizePresetToBaselineClearsHasUnsavedChanges() {
        let (_, vm, _) = makeSUT()
        vm.popoverSizePreset = .large
        XCTAssertTrue(vm.hasUnsavedChanges)

        vm.popoverSizePreset = .compact
        XCTAssertFalse(vm.hasUnsavedChanges)
    }

    func testSavePreferencesPersistsPopoverSizePresetToService() {
        let (service, vm, _) = makeSUT()
        XCTAssertEqual(service.popoverSizePreset, .compact)

        vm.popoverSizePreset = .large
        vm.savePreferences()

        XCTAssertEqual(service.popoverSizePreset, .large)
        XCTAssertEqual(service.popoverSize, PopoverSize.Preset.large.size)
        XCTAssertFalse(vm.hasUnsavedChanges)
    }

    /// Regression: the footer quick-switcher can change the preset while the Settings
    /// form is open. Saving an unrelated change must not revert that.
    func testSaveDoesNotClobberPresetChangedElsewhere() {
        let (service, vm, _) = makeSUT()

        // Simulate the footer switcher changing the size while Settings is open.
        service.popoverSizePreset = .large

        // User changes an unrelated setting and saves, without touching the size picker.
        vm.syncInterval = 450
        vm.savePreferences()

        XCTAssertEqual(service.popoverSizePreset, .large)
    }

    func testSavePreferencesPersistsGlobalJoinHotkeyEnabledToService() {
        let (service, vm, _) = makeSUT()

        XCTAssertTrue(vm.globalJoinHotkeyEnabled)
        vm.globalJoinHotkeyEnabled = false
        XCTAssertTrue(vm.hasUnsavedChanges)
        vm.savePreferences()

        XCTAssertFalse(service.globalJoinHotkeyEnabled)
        XCTAssertFalse(vm.hasUnsavedChanges)
    }

    func testDefaultDisplayTimeZoneIsMoscowAndClean() {
        let (service, vm, _) = makeSUT()
        XCTAssertEqual(vm.displayTimeZone, .fixed("Europe/Moscow"))
        XCTAssertEqual(service.displayTimeZoneOption, .fixed("Europe/Moscow"))
        XCTAssertFalse(vm.hasUnsavedChanges)
    }

    func testChangingDisplayTimeZoneMarksHasUnsavedChanges() {
        let (_, vm, _) = makeSUT()
        XCTAssertFalse(vm.hasUnsavedChanges)

        vm.displayTimeZone = .system
        XCTAssertTrue(vm.hasUnsavedChanges)
    }

    func testRevertingDisplayTimeZoneToBaselineClearsHasUnsavedChanges() {
        let (_, vm, _) = makeSUT()
        vm.displayTimeZone = .fixed("Asia/Vladivostok")
        XCTAssertTrue(vm.hasUnsavedChanges)

        vm.displayTimeZone = .fixed("Europe/Moscow")
        XCTAssertFalse(vm.hasUnsavedChanges)
    }

    func testSavePreferencesPersistsDisplayTimeZoneToService() {
        let (service, vm, _) = makeSUT()

        vm.displayTimeZone = .fixed("Europe/Samara")
        XCTAssertTrue(vm.hasUnsavedChanges)
        vm.savePreferences()

        XCTAssertEqual(service.displayTimeZoneOption, .fixed("Europe/Samara"))
        XCTAssertEqual(UserDefaults.standard.string(forKey: AppTimeZone.storageKey), "Europe/Samara")
        XCTAssertFalse(vm.hasUnsavedChanges)
    }

    func testChangingSyncIntervalMarksHasUnsavedChanges() {
        let (_, vm, _) = makeSUT()
        XCTAssertFalse(vm.hasUnsavedChanges)

        vm.syncInterval = 450
        XCTAssertTrue(vm.hasUnsavedChanges)
    }

    func testRevertingSyncIntervalToBaselineClearsHasUnsavedChanges() {
        let (_, vm, _) = makeSUT()
        vm.syncInterval = 450
        XCTAssertTrue(vm.hasUnsavedChanges)

        vm.syncInterval = Baseline.syncInterval
        XCTAssertFalse(vm.hasUnsavedChanges)
    }

    func testChangingNotificationLeadMinutesMarksHasUnsavedChanges() {
        let (_, vm, _) = makeSUT()
        vm.notificationLeadMinutes = 20
        XCTAssertTrue(vm.hasUnsavedChanges)
    }

    func testSavePreferencesPersistsMultipleFieldsAndClearsUnsaved() {
        let (service, vm, _) = makeSUT()
        vm.syncInterval = 420
        vm.notificationLeadMinutes = 15
        vm.menuBarDisplayMode = .status
        vm.notificationScreenPolicy = .main
        vm.meetingReminderSound = .ping
        vm.meetingEngagementScope = .allEvents
        vm.meetingEngagementDefaultPeriod = .sevenDays

        vm.savePreferences()

        XCTAssertEqual(service.syncInterval, 420, accuracy: 0.001)
        XCTAssertEqual(service.notificationLeadMinutes, 15)
        XCTAssertEqual(service.menuBarDisplayMode, .status)
        XCTAssertEqual(service.notificationScreenPolicy, .main)
        XCTAssertEqual(service.meetingReminderSound, .ping)
        XCTAssertEqual(service.meetingEngagementScope, .allEvents)
        XCTAssertEqual(service.engagementPeriod, .sevenDays)
        XCTAssertFalse(vm.hasUnsavedChanges)
    }

    func testSetLaunchAtLoginDoesNotMarkPreferencesUnsaved() {
        let (_, vm, _) = makeSUT()
        XCTAssertFalse(vm.hasUnsavedChanges)

        vm.setLaunchAtLogin(true)

        XCTAssertFalse(vm.hasUnsavedChanges)
    }

    // MARK: - Certificate trust

    // Trusting a server for the first time and accepting a certificate that *changed* under a
    // host we already pinned are different events. The second one must not leave the previous
    // certificate trusted: a pin that never forgets keeps honouring a certificate that may have
    // been rotated precisely because it leaked.

    private func isolateCertificateStore() {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("settingsvm-certs-\(UUID().uuidString)", isDirectory: true)
        TrustedCertificateStore.replaceStoreForTesting(
            TrustedCertificateStore.makeStore(
                secureStore: SecureStore(
                    directory: directory,
                    keyProvider: InMemorySecureStoreKeyProvider()
                ),
                defaults: UserDefaults(suiteName: "settingsvm.certs.\(UUID().uuidString)")!
            )
        )
    }

    private func pending(
        fingerprint: String,
        previous: Set<String>
    ) -> SettingsViewModel.PendingCertificateTrust {
        SettingsViewModel.PendingCertificateTrust(
            host: "mail.example.com",
            port: 443,
            fingerprint: fingerprint,
            details: nil,
            previousFingerprints: previous
        )
    }

    func testFirstTimeTrustIsNotTreatedAsAReplacement() {
        XCTAssertFalse(pending(fingerprint: "aa11", previous: []).isReplacingKnownCertificate)
        XCTAssertTrue(pending(fingerprint: "bb22", previous: ["aa11"]).isReplacingKnownCertificate)
    }

    func testConfirmingAnUnknownCertificatePinsIt() {
        isolateCertificateStore()
        let (_, vm, _) = makeSUT()
        let key = TrustedCertificateStore.key(host: "mail.example.com", port: 443)

        vm.pendingCertTrust = pending(fingerprint: "aa11", previous: [])
        vm.confirmCertificateTrust(localization: LocalizationService())

        XCTAssertEqual(TrustedCertificateStore.trustedFingerprints(forKey: key), ["aa11"])
        XCTAssertNil(vm.pendingCertTrust)
    }

    func testConfirmingAChangedCertificateDropsThePreviousPin() {
        isolateCertificateStore()
        let (_, vm, _) = makeSUT()
        let key = TrustedCertificateStore.key(host: "mail.example.com", port: 443)
        TrustedCertificateStore.trust(fingerprint: "aa11", forKey: key)

        vm.pendingCertTrust = pending(fingerprint: "bb22", previous: ["aa11"])
        vm.confirmCertificateTrust(localization: LocalizationService())

        XCTAssertEqual(TrustedCertificateStore.trustedFingerprints(forKey: key), ["bb22"])
        XCTAssertFalse(TrustedCertificateStore.isTrusted(fingerprint: "aa11", forKey: key))
    }

    private func makeSUT() -> (CalendarService, SettingsViewModel, FakeLaunchAtLoginManager) {
        let service = CalendarService(
            providers: [],
            eventCacheStore: TestEventCacheStore(),
            notificationService: TestNotificationService(),
            customMeetingReminders: TestMeetingReminderController(),
            loadPersistedAccounts: false,
            startBackgroundTasks: false
        )
        let launchManager = FakeLaunchAtLoginManager()
        let vm = SettingsViewModel(calendarService: service, launchAtLoginManager: launchManager)
        return (service, vm, launchManager)
    }

    nonisolated private static func removeTrackedPreferenceKeys() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "syncInterval")
        defaults.removeObject(forKey: "notificationLeadMinutes")
        defaults.removeObject(forKey: "meetingReminderSound")
        defaults.removeObject(forKey: NotificationScreenPolicy.defaultsKey)
        defaults.removeObject(forKey: "menuBarDisplayMode")
        defaults.removeObject(forKey: "dimPastMeetingsOnTimeline")
        defaults.removeObject(forKey: "globalJoinHotkeyEnabled")
        defaults.removeObject(forKey: "meetingEngagementStats.storage.v1")
        defaults.removeObject(forKey: "popoverSizePreset")
        defaults.removeObject(forKey: AppTimeZone.storageKey)
    }

    nonisolated private static func applyBaselineUserDefaults() {
        let defaults = UserDefaults.standard
        defaults.set(Baseline.syncInterval, forKey: "syncInterval")
        defaults.set(Baseline.notificationLeadMinutes, forKey: "notificationLeadMinutes")
        defaults.set(Baseline.sound.rawValue, forKey: "meetingReminderSound")
        defaults.set(Baseline.screen.rawValue, forKey: NotificationScreenPolicy.defaultsKey)
        defaults.set(Baseline.menuBar.rawValue, forKey: "menuBarDisplayMode")
    }
}

private final class TestEventCacheStore: EventCacheStoring {
    func load() -> EventCacheSnapshot? { nil }
    func save(events: [CalendarEvent], rangeStart: Date, rangeEnd: Date) {}
    func clear() {}
}

private actor TestNotificationService: NotificationServicing {
    func setup(localization: NotificationLocalization) {}
    func requestAuthorization() async {}
    func removeAllPendingMeetingNotifications() async {}
    func scheduleNotifications(for events: [CalendarEvent], leadMinutes: Int, localization: NotificationLocalization) async {}
}

@MainActor
private final class TestMeetingReminderController: CustomMeetingReminderControlling {
    func cancelAll(closeActiveReminder: Bool) {}
    func reschedule(events: [CalendarEvent], leadMinutes: Int, localization: NotificationLocalization, sound: MeetingReminderSound) {}
}

@MainActor
private final class FakeLaunchAtLoginManager: LaunchAtLoginManaging {
    var isEnabled: Bool = false
    var requiresApproval: Bool = false

    func register() throws {
        isEnabled = true
    }

    func unregister() throws {
        isEnabled = false
    }
}
