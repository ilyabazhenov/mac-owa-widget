import Foundation
import os.log

@MainActor
final class CalendarService: ObservableObject {
    @Published private(set) var events: [CalendarEvent] = []
    @Published private(set) var syncStatus: SyncStatus = .idle
    @Published private(set) var accounts: [CalendarAccount] = []

    private var providers: [any CalendarProvider] = []
    private let scheduler = SyncScheduler()
    private let notificationService = NotificationService()
    private let log = Logger(subsystem: "com.owawidget", category: "CalendarService")
    private var notificationLocalization: NotificationLocalization = .english

    private let accountsKey = "calendarAccounts"
    private let syncIntervalKey = "syncInterval"
    private let notificationLeadKey = "notificationLeadMinutes"

    var syncInterval: TimeInterval {
        get { UserDefaults.standard.double(forKey: syncIntervalKey).nonZero ?? 300 }
        set { UserDefaults.standard.set(newValue, forKey: syncIntervalKey) }
    }

    var notificationLeadMinutes: Int {
        get {
            let v = UserDefaults.standard.integer(forKey: notificationLeadKey)
            return v > 0 ? v : 10
        }
        set { UserDefaults.standard.set(newValue, forKey: notificationLeadKey) }
    }

    init() {
        loadAccounts()
        Task {
            await notificationService.setup(localization: notificationLocalization)
            await notificationService.requestAuthorization()
            await rebuildProviders()
            await startScheduler()
        }
    }

    // MARK: - Account management

    func addAccount(_ account: CalendarAccount, password: String) throws {
        try KeychainService.save(password: password, accountID: account.id)
        accounts.append(account)
        persistAccounts()
        Task { await rebuildProviders() }
    }

    func updateAccount(_ account: CalendarAccount, newPassword: String?) throws {
        if let pwd = newPassword {
            try KeychainService.save(password: pwd, accountID: account.id)
        }
        guard let idx = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[idx] = account
        persistAccounts()
        Task { await rebuildProviders() }
    }

    func removeAccount(_ account: CalendarAccount) throws {
        try KeychainService.delete(accountID: account.id)
        accounts.removeAll { $0.id == account.id }
        persistAccounts()
        Task { await rebuildProviders() }
    }

    // MARK: - Sync

    func syncNow() {
        Task { await performSync() }
    }

    func setNotificationLocalization(_ localization: NotificationLocalization) {
        notificationLocalization = localization
        let currentEvents = events
        let lead = notificationLeadMinutes
        Task {
            await notificationService.setup(localization: localization)
            await notificationService.scheduleNotifications(
                for: currentEvents,
                leadMinutes: lead,
                localization: localization
            )
        }
    }

    // MARK: - Internal

    func rebuildProviders() async {
        var built: [any CalendarProvider] = []
        for account in accounts {
            guard let password = try? KeychainService.load(accountID: account.id) else {
                log.warning("No password in Keychain for account \(account.displayName) — skipping")
                continue
            }
            switch account.accountType {
            case .owa:
                if let provider = try? OWACalendarProvider(account: account, password: password) {
                    built.append(provider)
                } else {
                    log.error("Failed to initialise OWACalendarProvider for \(account.displayName)")
                }
            case .googleCalendar:
                built.append(GoogleCalendarProvider(account: account))
            }
        }
        providers = built
        await performSync()
    }

    private func startScheduler() async {
        let interval = syncInterval
        await scheduler.start(interval: interval) { [weak self] in
            await self?.performSync()
        }
    }

    private func performSync() async {
        guard !providers.isEmpty else {
            syncStatus = .idle
            return
        }

        syncStatus = .syncing

        let now = Date()
        // Fetch from 30 min ago (catch in-progress meetings) to 7 days ahead
        let start = now.addingTimeInterval(-1800)
        let end = Calendar.current.date(byAdding: .day, value: 7, to: now) ?? now

        do {
            var fetched: [CalendarEvent] = []
            try await withThrowingTaskGroup(of: [CalendarEvent].self) { group in
                for provider in providers {
                    group.addTask { try await provider.fetchEvents(from: start, to: end) }
                }
                for try await batch in group {
                    fetched.append(contentsOf: batch)
                }
            }

            // Deduplicate by ID, then sort by start time
            var seen = Set<String>()
            events = fetched
                .filter { seen.insert($0.id).inserted }
                .sorted { $0.startDate < $1.startDate }

            syncStatus = .lastSynced(Date())
            log.info("Sync complete: \(self.events.count) events")

            let currentEvents = events
            let lead = notificationLeadMinutes
            await notificationService.scheduleNotifications(
                for: currentEvents,
                leadMinutes: lead,
                localization: notificationLocalization
            )

        } catch {
            syncStatus = .error(error.localizedDescription)
            log.error("Sync failed: \(error)")
        }
    }

    // MARK: - Persistence

    private func loadAccounts() {
        guard let data = UserDefaults.standard.data(forKey: accountsKey),
              let decoded = try? JSONDecoder().decode([CalendarAccount].self, from: data)
        else { return }
        accounts = decoded
    }

    private func persistAccounts() {
        if let data = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(data, forKey: accountsKey)
        }
    }
}

private extension Double {
    var nonZero: Double? { self > 0 ? self : nil }
}
