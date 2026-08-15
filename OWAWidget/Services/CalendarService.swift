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

    /// Selected popover size preset. Published so the popover frame and the footer
    /// quick-switcher update live; persisted on every change. Storing the preset (not a
    /// raw size) guarantees the popover is always one of the offered sizes.
    @Published var popoverSizePreset: PopoverSize.Preset = PopoverSizePresetStore.load() {
        didSet { PopoverSizePresetStore.save(popoverSizePreset) }
    }

    /// Pixel size for the popover frame, derived from the selected preset.
    var popoverSize: PopoverSize { popoverSizePreset.size }

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

    // MARK: - Auth circuit breaker

    /// Number of consecutive sync cycles that failed with an auth error (401/440).
    /// A single transient blip (session expiry, load-balancer hiccup, an AD lockout
    /// triggered by another stale device) should not latch the "wrong password" state,
    /// so we only suspend sync after `authFailureThreshold` failures in a row.
    private var consecutiveAuthFailures = 0

    /// Timestamp of the last auth-block probe (or of the moment we latched). While the
    /// breaker is tripped we let one probe sync through every `authProbeInterval` so a
    /// transient cause — or an AD lockout that has since cleared — self-heals without the
    /// user re-entering the password, and without hammering the server into a new lockout.
    private var lastAuthProbeAt: Date?

    /// Consecutive auth failures required before suspending sync. `2` rides out a single
    /// transient blip while latching on the next failure. Each failed cycle already costs
    /// ~2 credential submissions (the request plus one internal re-auth), so this is the
    /// dominant contributor to AD-lockout risk before the breaker engages — do not raise it
    /// carelessly. (`1` would match the pre-breaker attempt count exactly, at the cost of
    /// surfacing the message on every blip; recovery is handled by the auto-probe either way.)
    private let authFailureThreshold = 2

    /// Minimum spacing between auth-block probes. At one attempt per 30 min the app's own
    /// contribution stays far below any realistic AD lockout threshold/observation window.
    /// In DEBUG it can be shortened via the `OWA_AUTH_PROBE_INTERVAL_SECONDS` default so the
    /// auto-probe is observable live without waiting half an hour.
    #if DEBUG
    private var authProbeInterval: TimeInterval {
        let override = UserDefaults.standard.double(forKey: "OWA_AUTH_PROBE_INTERVAL_SECONDS")
        return override > 0 ? override : 30 * 60
    }
    #else
    private let authProbeInterval: TimeInterval = 30 * 60
    #endif

    /// Source of "now" for the auth breaker's time math. Injectable so probe timing is
    /// deterministically testable; defaults to the system clock in production.
    private let clock: () -> Date

    /// Encrypted account list. Server hostnames and mailbox addresses used to sit in the
    /// preferences plist in cleartext; the password has always lived in ``KeychainService`` and
    /// stays there — moving it here would have made it unrecoverable if either the container or
    /// the master key were lost, and it would not survive Migration Assistant.
    private let accountStore: SecureCodableStore<[CalendarAccount]>

    static func makeAccountStore(
        secureStore: SecureStore = .shared,
        defaults: UserDefaults = .standard
    ) -> SecureCodableStore<[CalendarAccount]> {
        SecureCodableStore(
            name: "accounts",
            legacyKey: "calendarAccounts",
            store: secureStore,
            defaults: defaults,
            // Accounts cannot be rebuilt from the network: keep the legacy copy until the
            // encrypted one is proven readable.
            policy: .fallBackToLegacy
        )
    }

    private let syncIntervalKey = "syncInterval"
    private let notificationLeadKey = "notificationLeadMinutes"
    private let meetingReminderStyleKey = "meetingReminderStyle"
    private let meetingReminderSoundKey = "meetingReminderSound"
    private let notificationScreenPolicyKey = NotificationScreenPolicy.defaultsKey
    private let notificationPositionKey = NotificationPosition.defaultsKey
    private let menuBarDisplayModeKey = "menuBarDisplayMode"
    private let dimPastMeetingsOnTimelineKey = "dimPastMeetingsOnTimeline"
    private let globalJoinHotkeyEnabledKey = "globalJoinHotkeyEnabled"
    private let displayTimeZoneKey = AppTimeZone.storageKey

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

    /// Display timezone used for all UI rendering and day boundaries (see `AppTimeZone`).
    /// Defaults to Moscow when unset, preserving the app's original behavior.
    var displayTimeZoneOption: DisplayTimeZoneOption {
        get { DisplayTimeZoneOption(storageValue: UserDefaults.standard.string(forKey: displayTimeZoneKey)) }
        set { UserDefaults.standard.set(newValue.storageValue, forKey: displayTimeZoneKey) }
    }

    init(
        providers: [any CalendarProvider] = [],
        eventCacheStore: any EventCacheStoring = EventCacheStore(),
        accountStore: SecureCodableStore<[CalendarAccount]> = CalendarService.makeAccountStore(),
        notificationService: any NotificationServicing = NotificationService(),
        customMeetingReminders: any CustomMeetingReminderControlling = CustomMeetingReminderController(),
        initialNotificationLocalization: NotificationLocalization = .english,
        loadPersistedAccounts: Bool = true,
        startBackgroundTasks: Bool = true,
        clock: @escaping () -> Date = { Date() }
    ) {
        self.providers = providers
        self.eventCacheStore = eventCacheStore
        self.accountStore = accountStore
        self.notificationService = notificationService
        self.customMeetingReminders = customMeetingReminders
        self.clock = clock
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

        // Drain the cleartext leftovers that nothing else on the startup path would touch.
        Task.detached(priority: .utility) {
            SecureStoreMigrator.runPendingMigrations()
        }

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

        // Writing to the encrypted store can genuinely fail — the master key lives in the
        // Keychain and the user can decline access. Silently keeping the account in memory would
        // show a working account that vanishes on the next launch, leaving its password behind as
        // an orphaned Keychain item. Roll the whole thing back instead and let the UI report it.
        guard persistAccounts() else {
            accounts.removeLast()
            try? KeychainService.delete(accountID: account.id)
            throw CalendarServiceError.accountPersistenceFailed
        }
        Task { await rebuildProviders() }
    }

    func updateAccount(_ account: CalendarAccount, newPassword: String?) throws {
        if let pwd = newPassword {
            try KeychainService.save(password: pwd, accountID: account.id)
        }
        guard let idx = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        let previous = accounts[idx]
        accounts[idx] = account

        guard persistAccounts() else {
            accounts[idx] = previous
            throw CalendarServiceError.accountPersistenceFailed
        }
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
        // No rollback here: the password and the pinned certificate are already gone, so putting
        // the account back would leave it unusable. Surface the failure instead — on the next
        // launch the account reappears from the stale container and has to be removed again.
        guard persistAccounts() else {
            throw CalendarServiceError.accountPersistenceFailed
        }
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

    /// Lifts an authentication block on explicit user request (the footer "retry" action)
    /// and forces an immediate sync, without requiring the user to re-enter the password.
    /// Use when the block was caused by a transient failure or an AD lockout that has since
    /// cleared. Resetting the breaker makes `performSync` bypass the auth guard for this run.
    func retryAfterAuthBlock() {
        guard liftAuthBlockForRetry() else { return }
        Task { await performSync(trigger: "manualAuthRetry") }
    }

    /// Records one auth failure — from a sync cycle or an action request (create/RSVP) — and
    /// decides whether to latch the breaker. Latches (suspending sync until a probe, the
    /// retry action, or a credential update lifts it) when a probe has just failed again, or
    /// once `authFailureThreshold` failures accumulate. Returns `true` when now latched.
    /// Below the threshold the visible status is left to the caller, so a sync keeps showing
    /// cached events and an action surfaces its own error.
    /// `definitive` marks a confirmed credential rejection (we reached the OWA logon surface and
    /// it declined to grant a session). That is not a transient blip, so it latches on the first
    /// failure instead of riding out `authFailureThreshold`. Ambiguous 401/440s on data requests
    /// (session expiry, an LB hiccup, an AD lockout from another device) pass `definitive: false`
    /// and keep the threshold grace.
    @discardableResult
    private func registerAuthFailure(isProbe: Bool, definitive: Bool) -> Bool {
        consecutiveAuthFailures += 1
        guard isProbe || definitive || consecutiveAuthFailures >= authFailureThreshold else {
            return false
        }
        syncStatus = .authenticationRequired
        lastAuthProbeAt = clock()
        return true
    }

    /// Resets the auth circuit breaker so the next `performSync` bypasses the guard.
    /// Returns `false` (and does nothing) when there is no auth block to lift.
    @discardableResult
    private func liftAuthBlockForRetry() -> Bool {
        guard syncStatus.isAuthenticationRequired else { return false }
        consecutiveAuthFailures = 0
        lastAuthProbeAt = nil
        syncStatus = .idle
        log.info("Manual auth-block retry requested")
        return true
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

    /// Awaitable counterpart of `retryAfterAuthBlock()` for tests — lifts the auth block and
    /// runs the forced sync inline instead of on a detached Task.
    func retryAfterAuthBlockForTests() async {
        guard liftAuthBlockForRetry() else { return }
        await performSync(trigger: "manualAuthRetry")
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

    /// Lazily loads attendees and the full agenda for a meeting (one `GetCalendarEvent` request)
    /// and caches both back onto the event in `events`. Returns the cached payload immediately if
    /// already loaded, so re-opening the same meeting performs no network request until the next
    /// sync replaces the event.
    func loadDetails(for event: CalendarEvent) async throws -> CalendarEventDetails {
        if let cached = events.first(where: { $0.id == event.id }), let attendees = cached.detailedAttendees {
            return CalendarEventDetails(attendees: attendees, body: cached.fullBody, bodyHTML: cached.fullBodyHTML)
        }
        guard let provider = providers.first(where: { $0.account.id == event.accountID }) else {
            throw CalendarProviderError.notSupported
        }
        let details = try await provider.fetchDetails(for: event)
        if let idx = events.firstIndex(where: { $0.id == event.id }) {
            events[idx] = events[idx].withDetails(details)
        }
        return details
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
            // Route through the shared breaker so a transient 401 on an action doesn't hard-latch
            // the whole app — an ambiguous 401/440 latches only at the threshold, while a confirmed
            // logon-page rejection latches immediately. Leaves `lastAuthProbeAt` correctly
            // initialised for the auto-probe.
            if registerAuthFailure(isProbe: false, definitive: OWAError.isDefinitiveAuthRejection(error)) {
                log.error("\(context, privacy: .public) suspended sync: auth error (failures=\(self.consecutiveAuthFailures, privacy: .public)) — \(error.localizedDescription, privacy: .public)")
            } else {
                log.warning("\(context, privacy: .public) transient auth failure \(self.consecutiveAuthFailures, privacy: .public)/\(self.authFailureThreshold, privacy: .public)")
            }
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
    /// Latches the auth circuit breaker immediately so the popover's "wrong password" UI
    /// (status text + footer/errorState "retry" buttons + tooltip) can be inspected live
    /// without provoking a real 401 (and the AD-lockout risk that comes with it).
    func debugForceAuthBlock() {
        consecutiveAuthFailures = authFailureThreshold
        syncStatus = .authenticationRequired
        lastAuthProbeAt = clock()
        log.info("DEBUG: forced auth block")
    }

    /// Feeds one simulated auth failure through the real breaker path, so you can watch it
    /// stay transient on the first failure and latch on the next (threshold behaviour).
    func debugSimulateAuthFailure() {
        if registerAuthFailure(isProbe: false, definitive: false) {
            log.info("DEBUG: simulated auth failure → latched")
        } else {
            syncStatus = events.isEmpty
                ? .error("debug auth failure")
                : .offlineCached("debug auth failure")
            log.info("DEBUG: simulated auth failure \(self.consecutiveAuthFailures, privacy: .public)/\(self.authFailureThreshold, privacy: .public) (transient)")
        }
    }

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
        // the server — lift any auth / certificate-trust block and reset the breaker.
        if syncStatus.blocksSync {
            syncStatus = .idle
        }
        consecutiveAuthFailures = 0
        lastAuthProbeAt = nil
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

        // Circuit breaker. A certificate-trust problem can't self-heal — it needs explicit
        // user action — so stay fully suspended until rebuildProviders() lifts it.
        if syncStatus.isCertificateTrustRequired {
            log.info("Sync \(syncID, privacy: .public) skipped: certificate trust required")
            return
        }

        // An auth block may be transient (session blip, an AD lockout that has since
        // cleared), so don't retry on every scheduler tick — that risks a fresh lockout —
        // but do let a single probe through every `authProbeInterval` so it can recover on
        // its own. `isAuthBlockProbe` tells the catch handler to re-latch (not reset) if the
        // probe fails again.
        var isAuthBlockProbe = false
        if syncStatus.isAuthenticationRequired {
            let elapsed = clock().timeIntervalSince(lastAuthProbeAt ?? .distantPast)
            guard elapsed >= authProbeInterval else {
                log.info("Sync \(syncID, privacy: .public) skipped: auth block, next probe in \(Int((self.authProbeInterval - elapsed).rounded()), privacy: .public)s")
                return
            }
            lastAuthProbeAt = clock()
            isAuthBlockProbe = true
            log.info("Sync \(syncID, privacy: .public) auth-block probe attempt")
        }

        syncStatus = .syncing

        let now = Date()
        // Use the display calendar so the fetched window's day boundaries align with the
        // timezone the UI groups events by ("today/tomorrow"), not the macOS system clock.
        // The boundaries are absolute `Date` instants; the wire format still formats them in
        // `TimeZone.current` to match the OWA `TimeZoneContext`.
        let calendar = AppTimeZone.calendar
        let todayStart = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -7, to: todayStart) ?? todayStart
        let end = calendar.date(byAdding: .day, value: 30, to: now) ?? now

        do {
            var fetched: [CalendarEvent] = []
            // KNOWN LIMITATION (multi-account): providers are fetched fail-fast — `for try await`
            // rethrows the first provider's error and cancels the rest, so a single account's
            // failure (e.g. a wrong password on one of two OWA accounts) aborts the whole cycle
            // before `events` is assigned, discarding a healthy account's freshly fetched events.
            // Combined with the app-wide `syncStatus`/breaker (one status for all accounts), one
            // bad account can suspend sync for a good one. This is acceptable today because the
            // dominant case is a single account (Google is a stub), so there is nothing to lose.
            // A proper fix is per-account fetch results + per-account breaker/status (see the
            // "#5" review note); intentionally deferred rather than half-built.
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
            consecutiveAuthFailures = 0
            lastAuthProbeAt = nil
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
                // Latching suspends the scheduler (preventing account lockout); a slow
                // auto-probe and the manual "retry" action can still lift it without the user
                // re-entering the password.
                if registerAuthFailure(isProbe: isAuthBlockProbe, definitive: OWAError.isDefinitiveAuthRejection(error)) {
                    log.error("Sync \(syncID, privacy: .public) suspended: auth error (failures=\(self.consecutiveAuthFailures, privacy: .public)) — \(error.localizedDescription, privacy: .public)")
                } else {
                    // Not latched yet — treat as transient: keep showing cached events and
                    // let the next scheduled cycle retry.
                    if events.isEmpty, let snapshot = eventCacheStore.load(), !snapshot.events.isEmpty {
                        events = snapshot.events.sorted { $0.startDate < $1.startDate }
                    }
                    syncStatus = events.isEmpty
                        ? .error(error.localizedDescription)
                        : .offlineCached(error.localizedDescription)
                    log.warning("Sync \(syncID, privacy: .public) transient auth failure \(self.consecutiveAuthFailures, privacy: .public)/\(self.authFailureThreshold, privacy: .public)")
                }
            } else if isAuthBlockProbe {
                // The probe hit a non-auth error (network/server), so it could NOT confirm the
                // block has cleared. Stay latched and reschedule the next probe rather than
                // dropping to a non-blocking status (which would let the scheduler hammer the
                // rejected credentials on the very next tick).
                syncStatus = .authenticationRequired
                lastAuthProbeAt = clock()
                log.warning("Sync \(syncID, privacy: .public) auth-block probe failed with non-auth error — staying latched: \(error.localizedDescription, privacy: .public)")
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
        guard let decoded = accountStore.load() else { return }

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

    @discardableResult
    private func persistAccounts() -> Bool {
        let saved = accountStore.save(accounts)
        if !saved {
            log.error("Failed to persist accounts to the encrypted store")
            DiagnosticLog.event("Account persistence failed count=\(accounts.count)")
        }
        return saved
    }
}

enum CalendarServiceError: Error, LocalizedError {
    /// The encrypted account store could not be written — most likely the master key in the
    /// Keychain is unavailable because the user declined the authorization prompt.
    case accountPersistenceFailed

    var errorDescription: String? {
        switch self {
        case .accountPersistenceFailed:
            "Could not save the account. Allow OWAWidget to access your keychain and try again."
        }
    }
}

private extension Double {
    var nonZero: Double? { self > 0 ? self : nil }
}
