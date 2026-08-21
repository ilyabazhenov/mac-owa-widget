import AppKit
import Foundation

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var accounts: [CalendarAccount] = []
    @Published var syncInterval: TimeInterval { didSet { updateUnsavedChanges() } }
    @Published var notificationLeadMinutes: Int { didSet { updateUnsavedChanges() } }
    @Published var meetingReminderSound: MeetingReminderSound { didSet { updateUnsavedChanges() } }
    @Published var meetingEngagementScope: MeetingEngagementScope { didSet { updateUnsavedChanges() } }
    @Published var meetingEngagementDefaultPeriod: MeetingEngagementPeriod { didSet { updateUnsavedChanges() } }
    @Published var notificationScreenPolicy: NotificationScreenPolicy { didSet { updateUnsavedChanges() } }
    @Published var notificationPosition: NotificationPosition { didSet { updateUnsavedChanges() } }
    @Published var menuBarDisplayMode: MenuBarDisplayMode { didSet { updateUnsavedChanges() } }
    @Published var popoverSizePreset: PopoverSize.Preset { didSet { updateUnsavedChanges() } }
    @Published var dimPastMeetingsOnTimeline: Bool { didSet { updateUnsavedChanges() } }
    @Published var globalJoinHotkeyEnabled: Bool { didSet { updateUnsavedChanges() } }
    @Published var displayTimeZone: DisplayTimeZoneOption { didSet { updateUnsavedChanges() } }
    @Published var launchAtLogin: Bool
    @Published var launchAtLoginRequiresApproval: Bool
    @Published private(set) var hasUnsavedChanges: Bool = false

    // Per-account edit state
    @Published var editingAccount: CalendarAccount?
    @Published var editingPassword: String = ""
    @Published var isAddingNew = false
    @Published var isTesting = false
    @Published var testResult: String?
    /// Set when a connection test hit an untrusted server certificate; drives the
    /// "trust this server?" confirmation. Nil otherwise.
    @Published var pendingCertTrust: PendingCertificateTrust?
    @Published var pendingLoginHostApproval: PendingLoginHostApproval?

    // MARK: EventKit account edit state

    @Published private(set) var eventKitAccess: EventKitAccessStatus = .notDetermined
    @Published private(set) var eventKitCalendars: [EventKitCalendarSnapshot] = []
    @Published private(set) var eventKitError: String?
    @Published private(set) var isLoadingEventKit = false
    @Published var selectedCalendarIdentifiers: Set<String> = []

    struct PendingCertificateTrust: Identifiable, Equatable {
        let host: String
        let port: Int
        let fingerprint: String
        let details: ServerCertificateDetails?
        /// Fingerprints already pinned for this host when the prompt was raised.
        ///
        /// Non-empty means the certificate *changed*, which is a different event from trusting a
        /// server for the first time: either a routine renewal, or someone sitting between the
        /// user and the server right now. The prompt has to say which question it is asking.
        let previousFingerprints: Set<String>

        var isReplacingKnownCertificate: Bool { !previousFingerprints.isEmpty }

        var id: String { "\(host):\(port):\(fingerprint)" }
    }

    /// The login flow was redirected at a host the user has not approved for this server, and the
    /// password was withheld. Federated sign-in and credential theft look identical from here, so
    /// the prompt names both hosts, shows the hops between them, and lets the user decide.
    struct PendingLoginHostApproval: Identifiable, Equatable {
        let configuredHost: String
        let loginHost: String
        let redirectChain: [String]

        var id: String { "\(configuredHost)->\(loginHost)" }
    }

    private let service: CalendarService
    private let launchAtLoginManager: any LaunchAtLoginManaging
    private let eventKitStore: any EventKitStoring
    private var baselinePreferences: PreferencesSnapshot

    init(
        calendarService: CalendarService,
        launchAtLoginManager: any LaunchAtLoginManaging = LaunchAtLoginService(),
        eventKitStore: any EventKitStoring = SystemEventKitStore.shared
    ) {
        self.service = calendarService
        self.launchAtLoginManager = launchAtLoginManager
        self.eventKitStore = eventKitStore
        self.accounts = calendarService.accounts
        self.syncInterval = calendarService.syncInterval
        self.notificationLeadMinutes = calendarService.notificationLeadMinutes
        self.meetingReminderSound = calendarService.meetingReminderSound
        self.meetingEngagementScope = calendarService.meetingEngagementScope
        self.meetingEngagementDefaultPeriod = calendarService.engagementPeriod
        self.notificationScreenPolicy = calendarService.notificationScreenPolicy
        self.notificationPosition = calendarService.notificationPosition
        self.menuBarDisplayMode = calendarService.menuBarDisplayMode
        self.popoverSizePreset = calendarService.popoverSizePreset
        self.dimPastMeetingsOnTimeline = calendarService.dimPastMeetingsOnTimeline
        self.globalJoinHotkeyEnabled = calendarService.globalJoinHotkeyEnabled
        self.displayTimeZone = calendarService.displayTimeZoneOption
        self.launchAtLogin = launchAtLoginManager.isEnabled
        self.launchAtLoginRequiresApproval = launchAtLoginManager.requiresApproval
        self.baselinePreferences = PreferencesSnapshot(
            syncInterval: calendarService.syncInterval,
            notificationLeadMinutes: calendarService.notificationLeadMinutes,
            meetingReminderSound: calendarService.meetingReminderSound,
            meetingEngagementScope: calendarService.meetingEngagementScope,
            meetingEngagementDefaultPeriod: calendarService.engagementPeriod,
            notificationScreenPolicy: calendarService.notificationScreenPolicy,
            notificationPosition: calendarService.notificationPosition,
            menuBarDisplayMode: calendarService.menuBarDisplayMode,
            popoverSizePreset: calendarService.popoverSizePreset,
            dimPastMeetingsOnTimeline: calendarService.dimPastMeetingsOnTimeline,
            globalJoinHotkeyEnabled: calendarService.globalJoinHotkeyEnabled,
            displayTimeZone: calendarService.displayTimeZoneOption
        )
        updateUnsavedChanges()
    }

    // MARK: - Connection test

    func testConnection(localization: LocalizationService) {
        guard let account = editingAccount else { return }
        isTesting = true
        testResult = nil
        pendingCertTrust = nil
        pendingLoginHostApproval = nil

        let pwd = editingPassword
        Task {
            do {
                let provider = try OWACalendarProvider(account: account, password: pwd)
                try await provider.validateCredentials()
                testResult = "✓ \(localization.tr("settings.account.connected"))"
            } catch {
                if let cert = OWAError.untrustedCertificateInfo(from: error) {
                    // Offer to trust this specific server certificate instead of a generic failure.
                    let key = TrustedCertificateStore.key(host: cert.host, port: cert.port)
                    pendingCertTrust = PendingCertificateTrust(
                        host: cert.host,
                        port: cert.port,
                        fingerprint: cert.fingerprint,
                        details: cert.details,
                        previousFingerprints: TrustedCertificateStore.trustedFingerprints(forKey: key)
                    )
                    testResult = nil
                } else if let redirect = OWAError.loginHostApprovalInfo(from: error) {
                    // Offer to approve this specific host instead of a generic failure — the same
                    // shape as the certificate prompt, for the same reason: the user is the only
                    // one who knows whether their organisation really signs in through that host.
                    pendingLoginHostApproval = PendingLoginHostApproval(
                        configuredHost: redirect.configuredHost,
                        loginHost: redirect.loginHost,
                        redirectChain: redirect.redirectChain
                    )
                    testResult = nil
                } else {
                    testResult = "✗ \(ConnectionTestMessage.failure(for: error, localization: localization))"
                }
            }
            isTesting = false
        }
    }

    /// User confirmed trust for the server certificate surfaced by `pendingCertTrust`.
    /// Pins the fingerprint and re-runs the connection test.
    func confirmCertificateTrust(localization: LocalizationService) {
        guard let pending = pendingCertTrust else { return }
        let key = TrustedCertificateStore.key(host: pending.host, port: pending.port)
        if pending.isReplacingKnownCertificate {
            // Keeping the old fingerprint alongside would leave the previous certificate trusted
            // forever, including one rotated because it leaked.
            TrustedCertificateStore.replace(fingerprint: pending.fingerprint, forKey: key)
        } else {
            TrustedCertificateStore.trust(fingerprint: pending.fingerprint, forKey: key)
        }
        pendingCertTrust = nil
        // Same dead store as above: cleared by `testConnection` before SwiftUI draws a frame.
        testConnection(localization: localization)
    }

    func cancelCertificateTrust() {
        pendingCertTrust = nil
    }

    /// User confirmed that this host is where their organisation's sign-in really lives.
    /// Records the approval and re-runs the connection test, which now gets as far as the POST.
    func confirmLoginHostApproval(localization: LocalizationService) {
        guard let pending = pendingLoginHostApproval else { return }
        TrustedLoginHostStore.approve(
            loginHost: pending.loginHost,
            forKey: TrustedLoginHostStore.key(configuredHost: pending.configuredHost)
        )
        pendingLoginHostApproval = nil
        // No interim "approved" message: `testConnection` clears `testResult` synchronously on
        // the next line, so it would never reach the screen. The re-run reports the real outcome.
        testConnection(localization: localization)
    }

    func cancelLoginHostApproval() {
        pendingLoginHostApproval = nil
    }

    // MARK: - Account CRUD

    func beginAddAccount() {
        editingAccount = CalendarAccount(displayName: "", serverURL: "", email: "")
        editingPassword = ""
        testResult = nil
        isAddingNew = true
        resetEventKitEditState()
    }

    /// Switches the account type mid-form, discarding the state that belongs to the other kind.
    func changeEditingAccountType(to type: AccountType) {
        guard var account = editingAccount, account.accountType != type else { return }
        account.accountType = type
        account.serverURL = ""
        account.email = ""
        account.calendarIdentifiers = nil
        account.sourceIdentifier = nil
        editingAccount = account
        editingPassword = ""
        testResult = nil
        pendingCertTrust = nil
        pendingLoginHostApproval = nil
        resetEventKitEditState()
        if type == .eventKit {
            Task { await refreshEventKitState() }
        }
    }

    func beginEditAccount(_ account: CalendarAccount) {
        editingAccount = account
        isAddingNew = false
        testResult = nil
        resetEventKitEditState()

        guard account.accountType.requiresPassword else {
            // No Keychain read at all: an EventKit account holds no secret, and reading one that
            // does not exist would still raise the system keychain dialog for nothing.
            editingPassword = ""
            selectedCalendarIdentifiers = Set(account.calendarIdentifiers ?? [])
            Task { await refreshEventKitState() }
            return
        }

        // Reading the password pops the system keychain-access dialog (drawn by
        // SecurityAgent). When it closes, focus stays with the system agent and the
        // settings window drops behind other apps. Re-activate ourselves so the
        // window — and the edit sheet about to open on it — comes back to the front.
        editingPassword = (try? KeychainService.load(accountID: account.id)) ?? ""
        NSApp.activate(ignoringOtherApps: true)
    }

    func saveAccount(localization: LocalizationService) {
        guard let account = editingAccount.map(normalizedForSaving) else { return }
        do {
            if isAddingNew {
                try service.addAccount(
                    account,
                    password: account.accountType.requiresPassword ? editingPassword : nil
                )
            } else {
                let pwd = (editingPassword.isEmpty || !account.accountType.requiresPassword)
                    ? nil
                    : editingPassword
                try service.updateAccount(account, newPassword: pwd)
            }
            accounts = service.accounts
            editingAccount = nil
            editingPassword = ""
            pendingCertTrust = nil
            pendingLoginHostApproval = nil
            resetEventKitEditState()
        } catch {
            testResult = localization.tr("settings.account.save.failed", error.localizedDescription)
        }
    }

    /// Dismisses the account edit sheet and wipes the in-memory password and transient
    /// test state so a plaintext password never lingers after the form closes.
    func cancelEditing() {
        editingAccount = nil
        editingPassword = ""
        testResult = nil
        pendingCertTrust = nil
        pendingLoginHostApproval = nil
        isAddingNew = false
        resetEventKitEditState()
    }

    // MARK: - EventKit accounts

    /// Calendars grouped by the account they come from, in a stable order.
    ///
    /// Built from the calendars themselves, which is what keeps the picker readable: this Mac
    /// reports several sources that hold no event calendars at all, and they would otherwise
    /// show up as empty headers.
    var eventKitCalendarGroups: [(source: String, calendars: [EventKitCalendarSnapshot])] {
        let grouped = Dictionary(grouping: eventKitCalendars, by: \.sourceTitle)
        return grouped
            .map { (source: $0.key, calendars: $0.value.sorted { $0.title < $1.title }) }
            .sorted { $0.source < $1.source }
    }

    var canSaveAccount: Bool {
        guard let account = editingAccount else { return false }
        switch account.accountType {
        case .owa, .googleCalendar:
            return !account.serverURL.isEmpty
                && !account.email.isEmpty
                && !(isAddingNew && editingPassword.isEmpty)
        case .eventKit:
            return eventKitAccess.canRead && !selectedCalendarIdentifiers.isEmpty
        }
    }

    func refreshEventKitState() async {
        isLoadingEventKit = true
        defer { isLoadingEventKit = false }
        eventKitAccess = await eventKitStore.authorizationStatus()
        guard eventKitAccess.canRead else {
            eventKitCalendars = []
            return
        }
        await loadCalendars()
    }

    /// Raises the system prompt. Only meaningful once — afterwards the user has to change the
    /// decision in System Settings, which is what the UI says when access is denied.
    func requestCalendarAccess() async {
        isLoadingEventKit = true
        defer { isLoadingEventKit = false }
        do {
            eventKitAccess = try await eventKitStore.requestAccess()
            eventKitError = nil
        } catch {
            eventKitAccess = await eventKitStore.authorizationStatus()
            eventKitError = error.localizedDescription
            return
        }
        guard eventKitAccess.canRead else { return }
        await loadCalendars()
    }

    func setCalendar(_ identifier: String, selected: Bool) {
        if selected {
            selectedCalendarIdentifiers.insert(identifier)
        } else {
            selectedCalendarIdentifiers.remove(identifier)
        }
    }

    func openCalendarPrivacySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    private func loadCalendars() async {
        do {
            eventKitCalendars = try await eventKitStore.calendars()
            eventKitError = nil
            // Drop selections whose calendar has since disappeared, so a stale identifier cannot
            // sit in the saved account forever, matching nothing.
            let known = Set(eventKitCalendars.map(\.identifier))
            selectedCalendarIdentifiers.formIntersection(known)
        } catch {
            eventKitCalendars = []
            eventKitError = error.localizedDescription
        }
    }

    private func resetEventKitEditState() {
        selectedCalendarIdentifiers = []
        eventKitCalendars = []
        eventKitError = nil
        isLoadingEventKit = false
    }

    /// Fills in what the form does not ask for directly before the account is persisted.
    private func normalizedForSaving(_ account: CalendarAccount) -> CalendarAccount {
        guard account.accountType == .eventKit else { return account }
        var result = account
        let selected = selectedCalendarIdentifiers.sorted()
        result.calendarIdentifiers = selected
        let sources = Set(
            eventKitCalendars
                .filter { selectedCalendarIdentifiers.contains($0.identifier) }
                .map(\.sourceIdentifier)
        )
        // Only meaningful when every selected calendar comes from one account; a mixed selection
        // has no single source to record.
        result.sourceIdentifier = sources.count == 1 ? sources.first : nil
        if result.displayName.trimmingCharacters(in: .whitespaces).isEmpty {
            result.displayName = defaultEventKitDisplayName(for: selected)
        }
        result.serverURL = ""
        result.email = ""
        return result
    }

    private func defaultEventKitDisplayName(for selected: [String]) -> String {
        let titles = Set(
            eventKitCalendars
                .filter { selected.contains($0.identifier) }
                .map(\.sourceTitle)
        )
        if titles.count == 1, let only = titles.first { return only }
        return AccountType.eventKit.displayName
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
        service.notificationPosition = notificationPosition
        service.menuBarDisplayMode = menuBarDisplayMode
        // Only write the popover preset if the user actually changed it here. The footer
        // quick-switcher can change `service.popoverSizePreset` while this (Save-gated)
        // form is open; an unconditional write would clobber that with our stale value.
        if popoverSizePreset != baselinePreferences.popoverSizePreset {
            service.popoverSizePreset = popoverSizePreset
        }
        service.dimPastMeetingsOnTimeline = dimPastMeetingsOnTimeline
        service.globalJoinHotkeyEnabled = globalJoinHotkeyEnabled
        service.displayTimeZoneOption = displayTimeZone
        service.setMeetingEngagementScope(meetingEngagementScope)
        service.setMeetingEngagementPeriod(meetingEngagementDefaultPeriod)
        service.applySavedPreferences()
        baselinePreferences = currentPreferencesSnapshot()
        updateUnsavedChanges()
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

    private struct PreferencesSnapshot: Equatable {
        let syncInterval: TimeInterval
        let notificationLeadMinutes: Int
        let meetingReminderSound: MeetingReminderSound
        let meetingEngagementScope: MeetingEngagementScope
        let meetingEngagementDefaultPeriod: MeetingEngagementPeriod
        let notificationScreenPolicy: NotificationScreenPolicy
        let notificationPosition: NotificationPosition
        let menuBarDisplayMode: MenuBarDisplayMode
        let popoverSizePreset: PopoverSize.Preset
        let dimPastMeetingsOnTimeline: Bool
        let globalJoinHotkeyEnabled: Bool
        let displayTimeZone: DisplayTimeZoneOption
    }

    private func currentPreferencesSnapshot() -> PreferencesSnapshot {
        PreferencesSnapshot(
            syncInterval: syncInterval,
            notificationLeadMinutes: notificationLeadMinutes,
            meetingReminderSound: meetingReminderSound,
            meetingEngagementScope: meetingEngagementScope,
            meetingEngagementDefaultPeriod: meetingEngagementDefaultPeriod,
            notificationScreenPolicy: notificationScreenPolicy,
            notificationPosition: notificationPosition,
            menuBarDisplayMode: menuBarDisplayMode,
            popoverSizePreset: popoverSizePreset,
            dimPastMeetingsOnTimeline: dimPastMeetingsOnTimeline,
            globalJoinHotkeyEnabled: globalJoinHotkeyEnabled,
            displayTimeZone: displayTimeZone
        )
    }

    private func updateUnsavedChanges() {
        hasUnsavedChanges = currentPreferencesSnapshot() != baselinePreferences
    }

    #if DEBUG
    func triggerTestReminderNow() {
        service.triggerTestReminderNow()
    }

    func debugForceAuthBlock() {
        service.debugForceAuthBlock()
    }

    func debugSimulateAuthFailure() {
        service.debugSimulateAuthFailure()
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
