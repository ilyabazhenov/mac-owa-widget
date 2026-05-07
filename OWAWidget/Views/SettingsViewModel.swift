import AppKit
import Foundation

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var accounts: [CalendarAccount] = []
    @Published var syncInterval: TimeInterval
    @Published var notificationLeadMinutes: Int
    @Published var meetingReminderSound: MeetingReminderSound
    @Published var meetingEngagementScope: MeetingEngagementScope
    @Published var meetingEngagementDefaultPeriod: MeetingEngagementPeriod
    @Published var notificationScreenPolicy: NotificationScreenPolicy
    @Published var menuBarDisplayMode: MenuBarDisplayMode
    @Published var launchAtLogin: Bool
    @Published var launchAtLoginRequiresApproval: Bool

    // Per-account edit state
    @Published var editingAccount: CalendarAccount?
    @Published var editingPassword: String = ""
    @Published var isAddingNew = false
    @Published var isTesting = false
    @Published var testResult: String?

    private let service: CalendarService
    private let launchAtLoginManager: any LaunchAtLoginManaging

    init(
        calendarService: CalendarService,
        launchAtLoginManager: any LaunchAtLoginManaging = LaunchAtLoginService()
    ) {
        self.service = calendarService
        self.launchAtLoginManager = launchAtLoginManager
        self.accounts = calendarService.accounts
        self.syncInterval = calendarService.syncInterval
        self.notificationLeadMinutes = calendarService.notificationLeadMinutes
        self.meetingReminderSound = calendarService.meetingReminderSound
        self.meetingEngagementScope = calendarService.meetingEngagementScope
        self.meetingEngagementDefaultPeriod = calendarService.engagementPeriod
        self.notificationScreenPolicy = calendarService.notificationScreenPolicy
        self.menuBarDisplayMode = calendarService.menuBarDisplayMode
        self.launchAtLogin = launchAtLoginManager.isEnabled
        self.launchAtLoginRequiresApproval = launchAtLoginManager.requiresApproval
    }

    // MARK: - Connection test

    func testConnection(localization: LocalizationService) {
        guard let account = editingAccount else { return }
        isTesting = true
        testResult = nil

        let pwd = editingPassword
        Task {
            do {
                let provider = try OWACalendarProvider(account: account, password: pwd)
                try await provider.validateCredentials()
                testResult = "✓ \(localization.tr("settings.account.connected"))"
            } catch {
                testResult = "✗ \(ConnectionTestMessage.failure(for: error, localization: localization))"
            }
            isTesting = false
        }
    }

    // MARK: - Account CRUD

    func beginAddAccount() {
        editingAccount = CalendarAccount(displayName: "", serverURL: "", email: "")
        editingPassword = ""
        testResult = nil
        isAddingNew = true
    }

    func beginEditAccount(_ account: CalendarAccount) {
        editingAccount = account
        editingPassword = (try? KeychainService.load(accountID: account.id)) ?? ""
        testResult = nil
        isAddingNew = false
    }

    func saveAccount(localization: LocalizationService) {
        guard let account = editingAccount else { return }
        do {
            if isAddingNew {
                try service.addAccount(account, password: editingPassword)
            } else {
                let pwd = editingPassword.isEmpty ? nil : editingPassword
                try service.updateAccount(account, newPassword: pwd)
            }
            accounts = service.accounts
            editingAccount = nil
        } catch {
            testResult = localization.tr("settings.account.save.failed", error.localizedDescription)
        }
    }

    func deleteAccount(_ account: CalendarAccount) {
        do {
            try service.removeAccount(account)
            accounts = service.accounts
        } catch {
            // Errors here are non-critical; log if needed
        }
    }

    // MARK: - Preferences

    func savePreferences() {
        service.syncInterval = syncInterval
        service.notificationLeadMinutes = notificationLeadMinutes
        service.meetingReminderSound = meetingReminderSound
        service.notificationScreenPolicy = notificationScreenPolicy
        service.menuBarDisplayMode = menuBarDisplayMode
        service.setMeetingEngagementScope(meetingEngagementScope)
        service.setMeetingEngagementPeriod(meetingEngagementDefaultPeriod)
        service.applySavedPreferences()
    }

    func previewMeetingReminderSound() {
        meetingReminderSound.play()
    }

    // MARK: - Launch at login

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try launchAtLoginManager.register()
            } else {
                try launchAtLoginManager.unregister()
            }
        } catch {
            // Reflect actual system state even when register/unregister fails.
        }
        refreshLaunchAtLoginState()
    }

    func openLoginItemsSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    private func refreshLaunchAtLoginState() {
        launchAtLogin = launchAtLoginManager.isEnabled
        launchAtLoginRequiresApproval = launchAtLoginManager.requiresApproval
    }

    #if DEBUG
    func triggerTestReminderNow() {
        service.triggerTestReminderNow()
    }

    var testReminderDelaySeconds: Double {
        get {
            let value = UserDefaults.standard.double(forKey: "OWA_TEST_DELAY_SECONDS")
            return value > 0 ? value : 2
        }
        set {
            let sanitized = max(0.5, min(newValue, 30))
            UserDefaults.standard.set(sanitized, forKey: "OWA_TEST_DELAY_SECONDS")
        }
    }
    #endif
}
