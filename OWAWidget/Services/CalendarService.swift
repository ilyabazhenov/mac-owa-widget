import AppKit
import Foundation
import os.log

protocol NotificationServicing: Actor {
    func setup(localization: NotificationLocalization)
    func requestAuthorization() async
    func removeAllPendingMeetingNotifications() async
    func scheduleNotifications(
        for events: [CalendarEvent],
        leadMinutes: Int,
        localization: NotificationLocalization
    ) async
}

@MainActor
protocol CustomMeetingReminderControlling: AnyObject {
    func cancelAll(closeActiveReminder: Bool)
    func reschedule(
        events: [CalendarEvent],
        leadMinutes: Int,
        localization: NotificationLocalization,
        sound: MeetingReminderSound
    )
}

@MainActor
final class CalendarService: ObservableObject {
    @Published private(set) var events: [CalendarEvent] = []
    @Published private(set) var syncStatus: SyncStatus = .idle
    @Published private(set) var accounts: [CalendarAccount] = []
    @Published private(set) var engagementSnapshot: MeetingEngagementSnapshot = .empty
    @Published private(set) var engagementPeriod: MeetingEngagementPeriod = .today

    private var providers: [any CalendarProvider] = []
    private let scheduler = SyncScheduler()
    private let notificationService: any NotificationServicing
    private let customMeetingReminders: any CustomMeetingReminderControlling
    private let eventCacheStore: any EventCacheStoring
    private let log = Logger(subsystem: "com.owawidget", category: "CalendarService")
    private let meetingEngagementStats = MeetingEngagementStatsService()
    private var notificationLocalization: NotificationLocalization
    private var nextSyncID = 0
    private var activeSyncIDs = Set<Int>()
    private var syncRequestGate = SyncRequestGate()

    private let accountsKey = "calendarAccounts"
    private let syncIntervalKey = "syncInterval"
    private let notificationLeadKey = "notificationLeadMinutes"
    private let meetingReminderStyleKey = "meetingReminderStyle"
    private let meetingReminderSoundKey = "meetingReminderSound"
    private let notificationScreenPolicyKey = NotificationScreenPolicy.defaultsKey
    private let notificationPositionKey = NotificationPosition.defaultsKey
    private let menuBarDisplayModeKey = "menuBarDisplayMode"
    private let dimPastMeetingsOnTimelineKey = "dimPastMeetingsOnTimeline"
    private let globalJoinHotkeyEnabledKey = "globalJoinHotkeyEnabled"

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
            guard let raw = UserDefaults.standard.string(forKey: meetingReminderStyleKey) else {
                return .inApp
            }
            if let style = MeetingReminderStyle(rawValue: raw) {
                return style
            }
            // Silent migration for legacy values ("system", "both").
            UserDefaults.standard.set(MeetingReminderStyle.inApp.rawValue, forKey: meetingReminderStyleKey)
            return .inApp
        }
        set { UserDefaults.standard.set(MeetingReminderStyle.inApp.rawValue, forKey: meetingReminderStyleKey) }
    }

    var notificationScreenPolicy: NotificationScreenPolicy {
        get { NotificationScreenPolicy.current }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: notificationScreenPolicyKey) }
    }

    var notificationPosition: NotificationPosition {
        get { NotificationPosition.current }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: notificationPositionKey) }
    }

    var meetingReminderSound: MeetingReminderSound {
        get {
            guard let raw = UserDefaults.standard.string(forKey: meetingReminderSoundKey),
                  let sound = MeetingReminderSound(rawValue: raw)
            else { return .default }
            return sound
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: meetingReminderSoundKey) }
    }

    var menuBarDisplayMode: MenuBarDisplayMode {
        get {
            guard let raw = UserDefaults.standard.string(forKey: menuBarDisplayModeKey),
                  let mode = MenuBarDisplayMode(rawValue: raw)
            else { return .countdown }
            return mode
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: menuBarDisplayModeKey) }
    }

    /// When `true` (default), ended meetings on today’s timeline render at reduced opacity.
    var dimPastMeetingsOnTimeline: Bool {
        get {
            if UserDefaults.standard.object(forKey: dimPastMeetingsOnTimelineKey) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: dimPastMeetingsOnTimelineKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: dimPastMeetingsOnTimelineKey) }
    }

    /// When `true` (default), Ctrl+Option+J joins current/next meeting globally.
    var globalJoinHotkeyEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: globalJoinHotkeyEnabledKey) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: globalJoinHotkeyEnabledKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: globalJoinHotkeyEnabledKey) }
    }

    init(
        providers: [any CalendarProvider] = [],
        eventCacheStore: any EventCacheStoring = EventCacheStore(),
        notificationService: any NotificationServicing = NotificationService(),
        customMeetingReminders: any CustomMeetingReminderControlling = CustomMeetingReminderController(),
        initialNotificationLocalization: NotificationLocalization = .english,
        loadPersistedAccounts: Bool = true,
        startBackgroundTasks: Bool = true
    ) {
        self.providers = providers
        self.eventCacheStore = eventCacheStore
        self.notificationService = notificationService
        self.customMeetingReminders = customMeetingReminders
        self.notificationLocalization = initialNotificationLocalization
        self.engagementPeriod = meetingEngagementStats.defaultPeriod
        if let reminderController = customMeetingReminders as? CustomMeetingReminderController {
            reminderController.onJoin = { [weak self] item in
                self?.openJoinURL(for: item, source: .inAppReminder)
                PostJoinDismissController.shared.dismissAfterJoin(context: .inAppReminder)
            }
        }
        if loadPersistedAccounts {
            loadAccounts()
        }
        loadCachedEvents()
        recalculateEngagementSnapshot()

        guard startBackgroundTasks else { return }

        DiagnosticLog.event(
            "CalendarService init accounts=\(accounts.count) cachedEvents=\(events.count)"
        )

        Task {
            await notificationService.setup(localization: notificationLocalization)
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
        // Drop any pinned (manually trusted) certificate for this server so a stale
        // fingerprint can't silently trust the host if the account is re-added later.
        if account.accountType == .owa,
           let base = try? OWAClient.parseBaseURL(account.serverURL),
           let host = base.host {
            TrustedCertificateStore.untrust(forKey: TrustedCertificateStore.key(host: host, port: base.port ?? 443))
        }
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
        guard notificationLocalization != localization else { return }
        notificationLocalization = localization
        Task { await rescheduleMeetingRemindersForCurrentEvents() }
    }

    /// Call after saving preferences from Settings (style, lead time, etc.).
    func applySavedPreferences() {
        objectWillChange.send()
        Task { await rescheduleMeetingRemindersForCurrentEvents() }
    }

    func performSyncForTests() async {
        await performSync(trigger: "tests")
    }

    func replaceEventsForTests(_ events: [CalendarEvent]) {
        self.events = events
        recalculateEngagementSnapshot()
    }

    var meetingEngagementScope: MeetingEngagementScope {
        meetingEngagementStats.scope
    }

    func setMeetingEngagementScope(_ scope: MeetingEngagementScope) {
        meetingEngagementStats.setScope(scope)
        recalculateEngagementSnapshot()
    }

    func setMeetingEngagementPeriod(_ period: MeetingEngagementPeriod) {
        engagementPeriod = period
        meetingEngagementStats.setDefaultPeriod(period)
        recalculateEngagementSnapshot()
    }

    // MARK: - Meeting creation

    private struct FindPeopleTimeoutError: Error {}

    func findPeople(query: String, accountID: UUID) async throws -> [ResolvedAttendee] {
        guard let provider = providers.first(where: { $0.account.id == accountID }) else { return [] }
        return try await withThrowingTaskGroup(of: [ResolvedAttendee].self) { group in
            group.addTask {
                try await provider.findPeople(query: query)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(40))
                throw FindPeopleTimeoutError()
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { return [] }
            return first
        }
    }

    func findFreeSlots(
        requiredEmails: [String],
        optionalEmails: [String] = [],
        range: DateInterval,
        displayRange: DateInterval? = nil,
        durationMinutes: Int,
        accountID: UUID
    ) async throws -> (slots: [FreeSlot], attendeeAvailability: [AttendeeAvailability], optionalAvailability: [AttendeeAvailability], organizerAvailability: AttendeeAvailability?, organizerEvents: [CalendarEvent]) {
        guard let provider = providers.first(where: { $0.account.id == accountID }) else { return ([], [], [], nil, []) }

        let cal = AppTimeZone.calendar
        let (requestStart, requestEnd) = UserAvailabilityRequestWindow.bounds(
            for: displayRange ?? range,
            referenceNow: Date(),
            calendar: cal
        )

        // Include organizer's own availability by resolving their SMTP email from the domain login.
        // Optional attendees are fetched in the same GetUserAvailability call (one round-trip),
        // but they only feed the hover-tooltip in the slot grid — never the slot search/ranking.
        let organizerSMTP = try? await provider.resolveOrganizerSMTPEmail()
        var allEmails = requiredEmails
        for email in optionalEmails where !allEmails.contains(email) {
            allEmails.append(email)
        }
        if let smtp = organizerSMTP, !allEmails.contains(smtp) {
            allEmails.insert(smtp, at: 0)
        }

        let availability: [AttendeeAvailability]
        if allEmails.isEmpty {
            availability = []
        } else {
            availability = try await provider.getUserAvailability(emails: allEmails, from: requestStart, to: requestEnd)
        }

        // Split returned rows into three buckets by email. Required participates in slot search,
        // optional is tooltip-only, organizer is its own variable used as a slot blocker.
        let requiredSet = Set(requiredEmails)
        let optionalSet = Set(optionalEmails)
        var attendeeAvailability: [AttendeeAvailability] = []
        var optionalAvailability: [AttendeeAvailability] = []
        var organizerAvailability: AttendeeAvailability? = nil
        for row in availability {
            if let smtp = organizerSMTP, row.email == smtp {
                organizerAvailability = row
            } else if requiredSet.contains(row.email) {
                attendeeAvailability.append(row)
            } else if optionalSet.contains(row.email) {
                optionalAvailability.append(row)
            }
        }

        // Treat as a real conflict on the organizer's calendar: anything that's on the calendar AND
        // the organizer hasn't declined / wasn't cancelled. Crucially, this keeps `.notResponded` —
        // those are invites pending the organizer's reply that the availability API often reports
        // as "free" (since the user hasn't accepted yet), but the organizer is realistically blocked.
        let organizerEvents = events.filter { ev in
            ev.accountID == accountID
                && !ev.isCancelled
                && ev.responseType != .declined
        }
        let slots = MeetingFreeSlotCalculator.compute(
            from: attendeeAvailability,
            optionalAvailability: optionalAvailability,
            organizerAvailability: organizerAvailability,
            organizerEvents: organizerEvents,
            range: range,
            durationMinutes: durationMinutes,
            referenceNow: Date()
        )
        return (slots: slots, attendeeAvailability: attendeeAvailability, optionalAvailability: optionalAvailability, organizerAvailability: organizerAvailability, organizerEvents: organizerEvents)
    }

    func createMeeting(
        title: String,
        agenda: String,
        location: String = "",
        slot: FreeSlot,
        requiredAttendees: [ResolvedAttendee],
        optionalAttendees: [ResolvedAttendee] = [],
        accountID: UUID
    ) async throws {
        guard let provider = providers.first(where: { $0.account.id == accountID }) else {
            throw OWAError.authenticationFailed("Account not found")
        }
        // Не пытаемся создать встречу, если синк заблокирован: отвергнутые creds (риск
        // lockout AD) ИЛИ недоверенный сертификат сервера.
        if syncStatus.blocksSync {
            throw OWAError.httpError(401, "Authentication or certificate trust required")
        }
        do {
            try await provider.createMeeting(
                title: title,
                agenda: agenda,
                location: location,
                start: slot.start,
                end: slot.end,
                requiredAttendees: requiredAttendees,
                optionalAttendees: optionalAttendees
            )
        } catch {
            applyBlockingError(error, context: "createMeeting")
            throw error
        }
        syncNow()
    }

    // MARK: - Meeting response

    func respondToMeeting(_ event: CalendarEvent, action: MeetingResponseAction) async throws {
        guard let provider = providers.first(where: { $0.account.id == event.accountID }) else { return }

        let optimisticType: MeetingResponseType
        switch action {
        case .accept:    optimisticType = .accepted
        case .tentative: optimisticType = .tentative
        case .decline:   optimisticType = .declined
        }

        applyResponseType(optimisticType, to: event.id)
        do {
            // RSVP runs here without a parallel TaskGroup timeout: URLSession already applies
            // `timeoutIntervalForRequest` on the EWS request, and an extra in-process race can
            // cancel the in-flight task and surface URLError.networkConnectionLost (-1005).
            try await provider.respondToMeeting(event, action: action)
            log.info("respondToMeeting succeeded eventID=\(event.id, privacy: .public)")
        } catch {
            applyResponseType(event.responseType, to: event.id)
            applyBlockingError(error, context: "respondToMeeting")
            log.error("respondToMeeting failed eventID=\(event.id, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    private func applyResponseType(_ type: MeetingResponseType, to eventID: String) {
        guard let idx = events.firstIndex(where: { $0.id == eventID }) else { return }
        events[idx] = events[idx].withResponseType(type)
    }

    /// Maps a request error onto a blocking sync status so the circuit breaker engages and
    /// the user gets an actionable state (re-enter password / re-trust the server) instead
    /// of repeated network calls against a rejecting or untrusted server.
    private func applyBlockingError(_ error: Error, context: String) {
        if let cert = OWAError.untrustedCertificateInfo(from: error) {
            syncStatus = .certificateTrustRequired(host: cert.host, fingerprint: cert.fingerprint)
            log.error("\(context, privacy: .public) suspended sync: untrusted certificate for \(cert.host, privacy: .public)")
        } else if OWAError.isAuthError(error) {
            syncStatus = .authenticationRequired
            log.error("\(context, privacy: .public) suspended sync: auth error — \(error.localizedDescription, privacy: .public)")
        }
    }

    func openJoinURL(for event: CalendarEvent, source: MeetingJoinSource) {
        guard let url = event.joinURLForActions else { return }
        // Only record the join if the URL was actually safe to open.
        guard MeetingURLOpener.open(url) else { return }
        meetingEngagementStats.trackJoin(for: event, source: source)
        recalculateEngagementSnapshot()
    }

    func openJoinURL(for reminderItem: MeetingReminderItem, source: MeetingJoinSource) {
        guard let url = reminderItem.joinURL else { return }
        guard MeetingURLOpener.open(url) else { return }
        meetingEngagementStats.trackJoin(eventID: reminderItem.eventID, startDate: reminderItem.startDate, source: source)
        recalculateEngagementSnapshot()
    }

    #if DEBUG
    func triggerTestReminderNow() {
        let now = Date()
        let start = now.addingTimeInterval(5 * 60)
        let end = start.addingTimeInterval(30 * 60)
        let accountID = accounts.first?.id ?? UUID()
        let event = CalendarEvent(
            id: "debug-reminder-\(UUID().uuidString)",
            title: "Debug reminder",
            startDate: start,
            endDate: end,
            location: "Online",
            bodyPreview: "Debug flow",
            joinURL: URL(string: "https://example.com/join"),
            platform: .teams,
            isAllDay: false,
            organizer: "OWA Widget",
            accountID: accountID
        )

        Task {
            let loc = notificationLocalization
            let lead = notificationLeadMinutes
            let sound = meetingReminderSound
            customMeetingReminders.reschedule(events: [event], leadMinutes: lead, localization: loc, sound: sound)
        }
    }
    #endif

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
        DiagnosticLog.event(
            "CalendarService providers rebuilt count=\(built.count) accounts=\(accounts.count)"
        )
        // A provider rebuild means the user explicitly updated credentials or re-trusted
        // the server — lift any auth / certificate-trust block.
        if syncStatus.blocksSync {
            syncStatus = .idle
        }
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
            customMeetingReminders.cancelAll(closeActiveReminder: true)
            await notificationService.removeAllPendingMeetingNotifications()
            return
        }

        // Circuit breaker: do not retry with credentials that were already rejected.
        // This prevents Exchange account lockout from repeated failed auth attempts.
        // Sync resumes when rebuildProviders() is called after a credential update.
        guard !syncStatus.blocksSync else {
            log.info("Sync \(syncID, privacy: .public) skipped: blocked (auth or certificate trust required)")
            return
        }

        syncStatus = .syncing

        let now = Date()
        let todayStart = Calendar.current.startOfDay(for: now)
        let start = Calendar.current.date(byAdding: .day, value: -7, to: todayStart) ?? todayStart
        let end = Calendar.current.date(byAdding: .day, value: 30, to: now) ?? now

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

            eventCacheStore.save(events: events, rangeStart: start, rangeEnd: end)
            syncStatus = .lastSynced(Date())
            syncRequestGate.recordSyncSucceeded()
            log.info("Sync \(syncID, privacy: .public) complete events=\(self.events.count, privacy: .public)")
            recalculateEngagementSnapshot()

            await rescheduleMeetingRemindersForCurrentEvents()

        } catch {
            if let certInfo = OWAError.untrustedCertificateInfo(from: error) {
                // Untrusted server certificate — suspend sync and surface an actionable
                // status so the user can re-trust the server (do NOT fail silently).
                syncStatus = .certificateTrustRequired(host: certInfo.host, fingerprint: certInfo.fingerprint)
                log.error("Sync \(syncID, privacy: .public) suspended: untrusted certificate for \(certInfo.host, privacy: .public)")
            } else if OWAError.isAuthError(error) {
                // Credentials definitively rejected — suspend sync to prevent account lockout.
                // Sync resumes only after an explicit credential update (rebuildProviders).
                syncStatus = .authenticationRequired
                log.error("Sync \(syncID, privacy: .public) suspended: auth error — \(error.localizedDescription, privacy: .public)")
            } else {
                if OWAError.isAbstractClassHTTPError(error) {
                    syncRequestGate.recordTransientFailure(at: Date())
                    log.warning("Sync \(syncID, privacy: .public) entered transient OWA cooldown")
                }
                if events.isEmpty, let snapshot = eventCacheStore.load(), !snapshot.events.isEmpty {
                    events = snapshot.events.sorted { $0.startDate < $1.startDate }
                }

                if events.isEmpty {
                    syncStatus = .error(error.localizedDescription)
                } else {
                    syncStatus = .offlineCached(error.localizedDescription)
                }
                log.error("Sync \(syncID, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
            await rescheduleMeetingRemindersForCurrentEvents()
        }
    }

    private func rescheduleMeetingRemindersForCurrentEvents() async {
        let currentEvents = events
        let lead = notificationLeadMinutes
        let loc = notificationLocalization
        let sound = meetingReminderSound

        await notificationService.removeAllPendingMeetingNotifications()
        customMeetingReminders.reschedule(events: currentEvents, leadMinutes: lead, localization: loc, sound: sound)
    }

    // MARK: - Persistence

    private func loadAccounts() {
        guard let data = UserDefaults.standard.data(forKey: accountsKey),
              let decoded = try? JSONDecoder().decode([CalendarAccount].self, from: data)
        else { return }

        // Migrate legacy cleartext http:// server URLs to https://. Before HTTPS was
        // enforced these could be persisted; without migration they'd now fail to build a
        // provider (parseBaseURL throws) and sync would silently stop with no UI signal.
        var migrated = false
        accounts = decoded.map { account in
            guard account.serverURL.lowercased().hasPrefix("http://") else { return account }
            migrated = true
            var updated = account
            updated.serverURL = "https://" + account.serverURL.dropFirst("http://".count)
            return updated
        }
        if migrated {
            persistAccounts()
            log.info("Migrated legacy http:// account URL(s) to https://")
        }
    }

    private func loadCachedEvents() {
        guard let snapshot = eventCacheStore.load() else { return }
        events = snapshot.events.sorted { $0.startDate < $1.startDate }
    }

    private func recalculateEngagementSnapshot(now: Date = Date()) {
        engagementSnapshot = meetingEngagementStats.snapshot(events: events, period: engagementPeriod, now: now)
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
