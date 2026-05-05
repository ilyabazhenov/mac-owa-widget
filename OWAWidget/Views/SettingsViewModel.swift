import Foundation

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var accounts: [CalendarAccount] = []
    @Published var syncInterval: TimeInterval
    @Published var notificationLeadMinutes: Int
    @Published var meetingReminderStyle: MeetingReminderStyle

    // Per-account edit state
    @Published var editingAccount: CalendarAccount?
    @Published var editingPassword: String = ""
    @Published var isAddingNew = false
    @Published var isTesting = false
    @Published var testResult: String?

    private let service: CalendarService

    init(calendarService: CalendarService) {
        self.service = calendarService
        self.accounts = calendarService.accounts
        self.syncInterval = calendarService.syncInterval
        self.notificationLeadMinutes = calendarService.notificationLeadMinutes
        self.meetingReminderStyle = calendarService.meetingReminderStyle
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
        service.meetingReminderStyle = meetingReminderStyle
        service.applySavedPreferences()
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
