import XCTest
@testable import OWAWidget

@MainActor
final class SettingsViewModelTests: XCTestCase {
    override func tearDown() {
        super.tearDown()
        UserDefaults.standard.removeObject(forKey: "menuBarDisplayMode")
    }

    func testSavePreferencesPersistsMenuBarDisplayModeToService() {
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

        vm.menuBarDisplayMode = .status
        vm.savePreferences()

        XCTAssertEqual(service.menuBarDisplayMode, .status)
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
