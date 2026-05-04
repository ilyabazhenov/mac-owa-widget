import Foundation

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var accounts: [CalendarAccount] = []
    @Published var syncInterval: TimeInterval
    @Published var notificationLeadMinutes: Int

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
    }

    // MARK: - Connection test

    func testConnection() {
        guard let account = editingAccount else { return }
        isTesting = true
        testResult = nil

        let pwd = editingPassword
        Task {
            do {
                let provider = try OWACalendarProvider(account: account, password: pwd)
                try await provider.validateCredentials()
                testResult = "✓ Connected successfully"
            } catch {
                testResult = "✗ \(error.localizedDescription)"
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

    func saveAccount() {
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
            testResult = "Save failed: \(error.localizedDescription)"
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
    }
}
