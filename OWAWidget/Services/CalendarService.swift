import AppKit
import EventKit
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

    /// `true` when the account store holds something this build could not read — most often a
    /// Keychain the user has not authorised yet after an update changed the app's code signature.
    ///
    /// Kept apart from "no accounts" because the two need opposite UI: the first-run empty state
    /// tells the user to add an account, and doing that writes a fresh list over the container
    /// that is still on disk. See ``SecureCodableStore/LoadOutcome``.
    @Published private(set) var accountStoreUnreadable = false
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
    /// Live only while an EventKit account exists. Removed when the last one goes away, and never
    /// torn down in `deinit`: the service is owned by the app and outlives every other object.
    private var eventStoreChangeObserver: NSObjectProtocol?
    private var eventStoreChangeDebounce: Task<Void, Never>?
    private let scheduler = SyncScheduler()
    private let notificationService: any NotificationServicing
    private let eventKitStore: any EventKitStoring
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
        // Injectable so tests can build EventKit-backed accounts without ever constructing an
        // `EKEventStore` — which would put the system calendar prompt one call away from a suite
        // that gates `make release-package`.
        eventKitStore: any EventKitStoring = SystemEventKitStore.shared,
        initialNotificationLocalization: NotificationLocalization = .english,
        loadPersistedAccounts: Bool = true,
        startBackgroundTasks: Bool = true,
        clock: @escaping () -> Date = { Date() }
    ) {
        self.providers = providers
        self.eventCacheStore = eventCacheStore
        self.accountStore = accountStore
        self.eventKitStore = eventKitStore
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

    /// First account able to back the create-meeting window, or `nil` when none can.
    ///
    /// Read-only providers (EventKit today) answer `notSupported` to `createMeeting`, so the entry
    /// points ask this before offering the action rather than letting a filled-in form fail on
    /// submit. Picking the first *capable* account also stops an EventKit account that happens to
    /// sort first from hijacking the window.
    var meetingCreationAccount: CalendarAccount? {
        accounts.first { $0.accountType.supportsMeetingCreation }
    }

    var supportsMeetingCreation: Bool { meetingCreationAccount != nil }

    // MARK: - Account management

    /// `password` is `nil` for account types that hold no secret of their own — an EventKit
    /// account is authorised once by the system calendar prompt, not by a credential we store.
    func addAccount(_ account: CalendarAccount, password: String?) throws {
        if let password, account.accountType.requiresPassword {
            try KeychainService.save(password: password, accountID: account.id)
        }
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

    /// Note that a password change is *not* undone if persisting the account then fails: the
    /// caller is told the update failed while the new password stays in the Keychain.
    ///
    /// Left that way deliberately. Rolling it back means reading the old password first, and the
    /// thing that makes the write fail — the Keychain being unavailable — is exactly what would
    /// make that read fail too, so the rollback would silently do nothing in its main case while
    /// looking like a guarantee. The practical impact is small: a password is normally changed
    /// here because it changed on the server, so the Keychain ends up holding the correct one.
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
        // Pointing the account at a different server invalidates every trust decision made for
        // the old one. Done after the write, so a failed persist (which puts `previous` back)
        // does not throw away decisions the account still depends on.
        if serverHost(of: previous) != serverHost(of: account) {
            revokeServerTrust(for: previous)
        }
        Task { await rebuildProviders() }
    }

    /// Host an account's server URL resolves to, or `nil` for a URL this client cannot parse.
    private func serverHost(of account: CalendarAccount) -> String? {
        guard account.accountType == .owa,
              let base = try? OWAClient.parseBaseURL(account.serverURL)
        else { return nil }
        return base.host.map { OWACredentialHostPolicy.normalizedHost($0) }
    }

    /// Drops the trust decisions scoped to this account's server: the pinned certificate and any
    /// approved login hosts.
    ///
    /// Both answer the same question — "may this server have your credentials?" — and neither may
    /// outlive the server it was given for. Left behind, they reapply in silence the moment that
    /// host comes back: a pin for a certificate that may have been rotated precisely because it
    /// leaked, or a federation host approved for an account that no longer exists.
    private func revokeServerTrust(for account: CalendarAccount) {
        guard account.accountType == .owa,
              let base = try? OWAClient.parseBaseURL(account.serverURL),
              let host = base.host
        else { return }
        TrustedCertificateStore.untrust(
            forKey: TrustedCertificateStore.key(host: host, port: base.port ?? 443)
        )
        TrustedLoginHostStore.revoke(forKey: TrustedLoginHostStore.key(configuredHost: host))
    }

    func removeAccount(_ account: CalendarAccount) throws {
        try KeychainService.delete(accountID: account.id)
        revokeServerTrust(for: account)
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
        guard manualSyncAllowed() else { return }
        Task { await performSync(trigger: "manual") }
    }

    /// Applies the request gate and records the attempt. Split out so the awaitable test
    /// counterpart runs the same decision instead of a copy of it.
    private func manualSyncAllowed() -> Bool {
        let now = Date()
        switch syncRequestGate.manualSyncDecision(now: now, hasActiveSync: !activeSyncIDs.isEmpty) {
        case .allow:
            syncRequestGate.recordSyncStarted(at: now)
            log.info("Manual sync requested")
            return true
        case .reject(let reason):
            log.info("Manual sync ignored reason=\(String(describing: reason), privacy: .public)")
            return false
        }
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

    func performSyncForTests(limitedTo accountTypes: Set<AccountType>? = nil) async {
        await performSync(trigger: "tests", limitedTo: accountTypes)
    }

    /// Awaitable counterpart of `syncNow()` for tests — applies the same request gate and runs the
    /// sync inline. Returns whether the gate let it through.
    @discardableResult
    func syncNowForTests() async -> Bool {
        guard manualSyncAllowed() else { return false }
        await performSync(trigger: "manual")
        return true
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
        } else if let redirect = OWAError.loginHostApprovalInfo(from: error) {
            syncStatus = .loginHostApprovalRequired(
                configuredHost: redirect.configuredHost,
                loginHost: redirect.loginHost
            )
            log.error("\(context, privacy: .public) suspended sync: login redirected to an unapproved host")
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
            switch account.accountType {
            case .owa:
                // Only credential-backed accounts need a Keychain entry, and a missing one is a
                // real failure for them: the provider cannot authenticate without it.
                guard let password = try? KeychainService.load(accountID: account.id) else {
                    log.warning("No password in Keychain for account \(account.displayName) — skipping")
                    continue
                }
                if let provider = try? OWACalendarProvider(account: account, password: password) {
                    built.append(provider)
                } else {
                    log.error("Failed to initialise OWACalendarProvider for \(account.displayName)")
                }
            case .googleCalendar:
                built.append(GoogleCalendarProvider(account: account))
            case .eventKit:
                built.append(EventKitCalendarProvider(account: account, store: eventKitStore))
            }
        }
        providers = built
        updateEventStoreObservation()
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

    /// Subscribes to system calendar changes while at least one EventKit account exists.
    ///
    /// The poll interval is the wrong instrument here: EventKit is a local database, and the
    /// system decides when it talks to Google. `EKEventStoreChanged` is the moment that database
    /// actually changed, so accepting a meeting on the phone shows up here in seconds instead of
    /// on the next tick.
    private func updateEventStoreObservation() {
        let needsObserver = accounts.contains { $0.accountType == .eventKit }

        if needsObserver, eventStoreChangeObserver == nil {
            eventStoreChangeObserver = NotificationCenter.default.addObserver(
                forName: .EKEventStoreChanged,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                // The capture has to be on *this* closure. A `[weak self]` on the inner Task
                // still needs the enclosing block to hold `self` to form it, and NotificationCenter
                // owns that block — so the service would never deallocate.
                Task { @MainActor in
                    self?.scheduleEventStoreRefresh()
                }
            }
            log.info("Subscribed to EKEventStoreChanged")
        } else if !needsObserver, let observer = eventStoreChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            eventStoreChangeObserver = nil
            eventStoreChangeDebounce?.cancel()
            eventStoreChangeDebounce = nil
            log.info("Unsubscribed from EKEventStoreChanged")
        }
    }

    /// Debounced because a single sync pass in the Calendar daemon fires the notification
    /// repeatedly — once per changed calendar — and each one would otherwise start a full sync.
    private func scheduleEventStoreRefresh() {
        eventStoreChangeDebounce?.cancel()
        eventStoreChangeDebounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            // Only the EventKit providers. This trigger fires whenever the system Calendar
            // daemon touches its database — several times an hour on an active account, and at
            // times nobody here controls. Running a full sync would put a network request to the
            // Exchange server behind every one of them, ignoring `syncInterval` and the request
            // gate that exist precisely to keep that server unhammered.
            await self?.performSync(trigger: "eventStoreChanged", limitedTo: [.eventKit])
        }
    }

    private func startScheduler() async {
        let interval = syncInterval
        await scheduler.start(interval: interval) { [weak self] in
            await self?.performSync(trigger: "scheduler")
        }
    }

    /// - Parameter limitedTo: when set, only providers of these account types are fetched.
    ///   Events of the untouched accounts are preserved, not dropped.
    private func performSync(trigger: String, limitedTo accountTypes: Set<AccountType>? = nil) async {
        nextSyncID += 1
        let syncID = nextSyncID
        let activeBefore = activeSyncIDs.count
        activeSyncIDs.insert(syncID)
        if accountTypes == nil {
            // Only full syncs stamp the gate. It throttles manual refreshes to keep bursts from
            // amplifying OWA faults, and a partial sync generates no OWA traffic to throttle —
            // stamping it would silently turn the user's "sync now" into a no-op for 15 seconds
            // because a system calendar change happened to fire.
            syncRequestGate.recordSyncStarted(at: Date())
        }
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

        let activeProviders = accountTypes.map { allowed in
            providers.filter { allowed.contains($0.account.accountType) }
        } ?? providers

        if accountTypes != nil {
            guard !activeProviders.isEmpty else {
                log.info("Sync \(syncID, privacy: .public) skipped: no providers of the requested kind")
                return
            }
            // A partial sync must never speak for the accounts it did not touch. Letting one run
            // while a block is latched would end with the success path resetting
            // `consecutiveAuthFailures` — clearing an Exchange wrong-password latch because a
            // local calendar read went fine, and handing the AD lockout risk straight back.
            guard !syncStatus.blocksSync else {
                log.info("Sync \(syncID, privacy: .public) skipped: partial sync while sync is blocked")
                return
            }
        }

        // Circuit breaker. A certificate-trust problem can't self-heal — it needs explicit
        // user action — so stay fully suspended until rebuildProviders() lifts it.
        if syncStatus.isCertificateTrustRequired {
            log.info("Sync \(syncID, privacy: .public) skipped: certificate trust required")
            return
        }

        // Neither can an unapproved login host: the answer is a decision only the user can make,
        // and retrying just re-runs a login that stops before it sends anything.
        if syncStatus.isLoginHostApprovalRequired {
            log.info("Sync \(syncID, privacy: .public) skipped: login host approval required")
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

        // Kept because `.syncing` overwrites it a line below: a partial run that succeeds must be
        // able to put a still-unresolved failure back rather than claim everything is fine.
        let statusBeforeSync = syncStatus
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
            // Providers are fetched independently and their failures collected rather than
            // rethrown on the spot. Fail-fast was harmless while OWA was the only real provider;
            // with a second one a revoked calendar permission would abort the cycle mid-flight and
            // throw away a healthy Exchange account's freshly fetched events.
            //
            // Still ONE app-wide `syncStatus` and one breaker: the first failure is rethrown below
            // so the existing classification (certificate / login host / auth latching) runs
            // unchanged. What changed is that it now runs *after* the surviving events are in
            // place, so the catch block reports `offlineCached` over real data instead of `error`
            // over nothing. Per-account status remains the deferred "#5" review item.
            var fetchedByAccount: [UUID: [CalendarEvent]] = [:]
            var failures: [Error] = []

            await SyncDiagnostics.$syncID.withValue(syncID) {
                await withTaskGroup(of: (UUID, Result<[CalendarEvent], Error>).self) { group in
                    for provider in activeProviders {
                        let accountID = provider.account.id
                        group.addTask {
                            do {
                                return (accountID, .success(try await provider.fetchEvents(from: start, to: end)))
                            } catch {
                                return (accountID, .failure(error))
                            }
                        }
                    }
                    for await (accountID, result) in group {
                        switch result {
                        case .success(let batch): fetchedByAccount[accountID] = batch
                        case .failure(let error): failures.append(error)
                        }
                    }
                }
            }

            // Nothing came back at all: leave both the in-memory events and the cache exactly as
            // they were. The catch block owns that case — it decides between showing what is
            // already on screen and restoring the disk snapshot — and writing an empty set here
            // would destroy the very snapshot it falls back to.
            if !fetchedByAccount.isEmpty {
                // Events are kept only for accounts that still have a provider and were not
                // refreshed in this pass — one that failed, or one a partial sync did not touch.
                //
                // The membership test matters: keying off "not refreshed" alone would also match
                // an account that no longer exists, and its meetings would then be merged back in
                // on every sync and written to the cache, outliving the account that produced them.
                let knownAccountIDs = Set(providers.map(\.account.id))
                let refreshedAccountIDs = Set(fetchedByAccount.keys)
                let retained = events.filter {
                    knownAccountIDs.contains($0.accountID) && !refreshedAccountIDs.contains($0.accountID)
                }

                // Deduplicate by ID, then sort by start time
                var seen = Set<String>()
                events = (fetchedByAccount.values.flatMap { $0 } + retained)
                    .filter { seen.insert($0.id).inserted }
                    .sorted { $0.startDate < $1.startDate }

                // Saved before any failure is surfaced: `events` already holds the complete
                // picture, and a failure that persists would otherwise freeze the cache at the
                // last fully clean sync — leaving the next launch to restore meetings from before
                // the problem started.
                eventCacheStore.save(events: events, rangeStart: start, rangeEnd: end)
            }

            if let failure = failures.first {
                throw failure
            }

            if accountTypes == nil {
                syncStatus = .lastSynced(Date())
                consecutiveAuthFailures = 0
                lastAuthProbeAt = nil
                syncRequestGate.recordSyncSucceeded()
            } else if statusBeforeSync.isError || statusBeforeSync.isOfflineCached {
                // A partial run speaks only for the accounts it fetched. Reporting success here
                // would paper over an account it never touched — and, worse, clearing the breaker
                // would mean a local calendar read resets the counter that stops the app from
                // retrying rejected Exchange credentials into an AD lockout. With a threshold of
                // two, an interleaved partial sync would keep it at one forever.
                syncStatus = statusBeforeSync
            } else {
                syncStatus = .lastSynced(Date())
            }
            log.info("Sync \(syncID, privacy: .public) complete events=\(self.events.count, privacy: .public)")
            recalculateEngagementSnapshot()

            await rescheduleMeetingRemindersForCurrentEvents()

        } catch {
            if let certInfo = OWAError.untrustedCertificateInfo(from: error) {
                // Untrusted server certificate — suspend sync and surface an actionable
                // status so the user can re-trust the server (do NOT fail silently).
                syncStatus = .certificateTrustRequired(host: certInfo.host, fingerprint: certInfo.fingerprint)
                log.error("Sync \(syncID, privacy: .public) suspended: untrusted certificate for \(certInfo.host, privacy: .public)")
            } else if let redirect = OWAError.loginHostApprovalInfo(from: error) {
                // Same shape as the certificate case: suspend and surface something the user can
                // act on, rather than retrying a login that deliberately refused to send the
                // password.
                syncStatus = .loginHostApprovalRequired(
                    configuredHost: redirect.configuredHost,
                    loginHost: redirect.loginHost
                )
                log.error("Sync \(syncID, privacy: .public) suspended: login redirected to an unapproved host")
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

    /// Re-reads the account store, for the UI to offer after the user has granted Keychain access.
    ///
    /// Does nothing beyond re-reading while the store stays unreadable: the caller is meant to
    /// keep showing the explanatory screen rather than fall through to "add an account".
    func retryLoadingAccounts() {
        loadAccounts()
        guard !accountStoreUnreadable, !accounts.isEmpty else { return }
        Task {
            await rebuildProviders()
            syncNow()
        }
    }

    private func loadAccounts() {
        guard let decoded = accountStore.load() else {
            accountStoreUnreadable = accountStore.lastLoadOutcome == .unreadable
            return
        }
        accountStoreUnreadable = false

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
