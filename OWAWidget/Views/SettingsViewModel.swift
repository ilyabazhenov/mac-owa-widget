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
    private var baselinePreferences: PreferencesSnapshot

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
    }

    func beginEditAccount(_ account: CalendarAccount) {
        editingAccount = account
        // Reading the password pops the system keychain-access dialog (drawn by
        // SecurityAgent). When it closes, focus stays with the system agent and the
        // settings window drops behind other apps. Re-activate ourselves so the
        // window — and the edit sheet about to open on it — comes back to the front.
        editingPassword = (try? KeychainService.load(accountID: account.id)) ?? ""
        NSApp.activate(ignoringOtherApps: true)
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
            editingPassword = ""
            pendingCertTrust = nil
            pendingLoginHostApproval = nil
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
