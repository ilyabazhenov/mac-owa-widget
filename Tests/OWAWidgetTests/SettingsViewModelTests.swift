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

    func testSavePreferencesPersistsMenuBarDisplayModeToService() {
        let (service, vm, _) = makeSUT()

        XCTAssertFalse(vm.hasUnsavedChanges)
        vm.menuBarDisplayMode = .status
        XCTAssertTrue(vm.hasUnsavedChanges)
        vm.savePreferences()

        XCTAssertEqual(service.menuBarDisplayMode, .status)
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
        defaults.removeObject(forKey: "meetingEngagementStats.storage.v1")
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
