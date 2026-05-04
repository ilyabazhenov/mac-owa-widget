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
    private let customMeetingReminders = CustomMeetingReminderController()
    private let log = Logger(subsystem: "com.owawidget", category: "CalendarService")
    private var notificationLocalization: NotificationLocalization = .english
    private var nextSyncID = 0
    private var activeSyncIDs = Set<Int>()
    private var syncRequestGate = SyncRequestGate()

    private let accountsKey = "calendarAccounts"
    private let syncIntervalKey = "syncInterval"
    private let notificationLeadKey = "notificationLeadMinutes"
    private let meetingReminderStyleKey = "meetingReminderStyle"

    var syncInterval: TimeInterval {
        get { UserDefaults.standard.double(forKey: syncIntervalKey).nonZero ?? 300 }
        set { UserDefaults.standard.set(newValue, forKey: syncIntervalKey) }
    }

    var notificationLeadMinutes: Int {
        get {
            let v = UserDefaults.standard.integer(forKey: notificationLeadKey)
            return v > 0 ? v : 1
        }
        set { UserDefaults.standard.set(newValue, forKey: notificationLeadKey) }
    }

    var meetingReminderStyle: MeetingReminderStyle {
        get {
            guard let raw = UserDefaults.standard.string(forKey: meetingReminderStyleKey),
                  let style = MeetingReminderStyle(rawValue: raw)
            else { return .inApp }
            return style
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: meetingReminderStyleKey) }
    }

    init() {
        loadAccounts()
        Task {
            await notificationService.setup(localization: notificationLocalization)
            if meetingReminderStyle.usesSystemNotifications {
                await notificationService.requestAuthorization()
            }
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
        let now = Date()
        switch syncRequestGate.manualSyncDecision(now: now, hasActiveSync: !activeSyncIDs.isEmpty) {
        case .allow:
            syncRequestGate.recordSyncStarted(at: now)
            log.info("Manual sync requested")
        case .reject(let reason):
            log.info("Manual sync ignored reason=\(String(describing: reason), privacy: .public)")
            return
        }

        Task { await performSync(trigger: "manual") }
    }

    func setNotificationLocalization(_ localization: NotificationLocalization) {
        notificationLocalization = localization
        Task { await rescheduleMeetingRemindersForCurrentEvents() }
    }

    /// Call after saving preferences from Settings (style, lead time, etc.).
    func applySavedPreferences() {
        Task { await rescheduleMeetingRemindersForCurrentEvents() }
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
        await performSync(trigger: "rebuildProviders")
    }

    private func startScheduler() async {
        let interval = syncInterval
        await scheduler.start(interval: interval) { [weak self] in
            await self?.performSync(trigger: "scheduler")
        }
    }

    private func performSync(trigger: String) async {
        nextSyncID += 1
        let syncID = nextSyncID
        let activeBefore = activeSyncIDs.count
        activeSyncIDs.insert(syncID)
        syncRequestGate.recordSyncStarted(at: Date())
        log.info(
            "Sync \(syncID, privacy: .public) started trigger=\(trigger, privacy: .public) providers=\(self.providers.count, privacy: .public) activeBefore=\(activeBefore, privacy: .public)"
        )
        defer {
            activeSyncIDs.remove(syncID)
            log.info(
                "Sync \(syncID, privacy: .public) finished activeRemaining=\(self.activeSyncIDs.count, privacy: .public)"
            )
        }

        guard !providers.isEmpty else {
            syncStatus = .idle
            log.info("Sync \(syncID, privacy: .public) skipped: no providers")
            customMeetingReminders.cancelAll()
            await notificationService.removeAllPendingMeetingNotifications()
            return
        }

        syncStatus = .syncing

        let now = Date()
        // Fetch from today's start to include already finished meetings from today.
        let start = Calendar.current.startOfDay(for: now)
        let end = Calendar.current.date(byAdding: .day, value: 7, to: now) ?? now

        do {
            var fetched: [CalendarEvent] = []
            try await SyncDiagnostics.$syncID.withValue(syncID) {
                try await withThrowingTaskGroup(of: [CalendarEvent].self) { group in
                    for provider in providers {
                        group.addTask { try await provider.fetchEvents(from: start, to: end) }
                    }
                    for try await batch in group {
                        fetched.append(contentsOf: batch)
                    }
                }
            }

            // Deduplicate by ID, then sort by start time
            var seen = Set<String>()
            events = fetched
                .filter { seen.insert($0.id).inserted }
                .sorted { $0.startDate < $1.startDate }

            syncStatus = .lastSynced(Date())
            syncRequestGate.recordSyncSucceeded()
            log.info("Sync \(syncID, privacy: .public) complete events=\(self.events.count, privacy: .public)")

            await rescheduleMeetingRemindersForCurrentEvents()

        } catch {
            if OWAError.isAbstractClassHTTPError(error) {
                syncRequestGate.recordTransientFailure(at: Date())
                log.warning("Sync \(syncID, privacy: .public) entered transient OWA cooldown")
            }
            syncStatus = .error(error.localizedDescription)
            log.error("Sync \(syncID, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func rescheduleMeetingRemindersForCurrentEvents() async {
        let currentEvents = events
        let lead = notificationLeadMinutes
        let loc = notificationLocalization
        let style = meetingReminderStyle

        switch style {
        case .system:
            customMeetingReminders.cancelAll()
            await notificationService.removeAllPendingMeetingNotifications()
            await notificationService.setup(localization: loc)
            await notificationService.requestAuthorization()
            await notificationService.scheduleNotifications(
                for: currentEvents,
                leadMinutes: lead,
                localization: loc
            )

        case .inApp:
            await notificationService.removeAllPendingMeetingNotifications()
            customMeetingReminders.cancelAll()
            customMeetingReminders.reschedule(events: currentEvents, leadMinutes: lead, localization: loc)

        case .both:
            await notificationService.removeAllPendingMeetingNotifications()
            customMeetingReminders.cancelAll()
            await notificationService.setup(localization: loc)
            await notificationService.requestAuthorization()
            await notificationService.scheduleNotifications(
                for: currentEvents,
                leadMinutes: lead,
                localization: loc
            )
            customMeetingReminders.reschedule(events: currentEvents, leadMinutes: lead, localization: loc)
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
