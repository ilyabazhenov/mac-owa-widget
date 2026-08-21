import SwiftUI

struct SettingsView: View {
    @StateObject private var vm: SettingsViewModel
    @EnvironmentObject private var localization: LocalizationService
    @State private var accountPendingDeletion: CalendarAccount?

    init(calendarService: CalendarService) {
        _vm = StateObject(wrappedValue: SettingsViewModel(calendarService: calendarService))
    }

    var body: some View {
        TabView {
            accountsTab
                .tabItem { Label(localization.tr("settings.tab.accounts"), systemImage: "person.2") }
                .onAppear { DiagnosticLog.event("SettingsView accounts tab appeared") }

            PreferencesView(vm: vm)
                .tabItem { Label(localization.tr("settings.tab.preferences"), systemImage: "slider.horizontal.3") }
                .onAppear { DiagnosticLog.event("SettingsView preferences tab appeared") }

            AboutView()
                .tabItem { Label(localization.tr("settings.tab.about"), systemImage: "info.circle") }
                .onAppear { DiagnosticLog.event("SettingsView about tab appeared") }
        }
        .frame(width: 480)
        .onAppear { DiagnosticLog.event("SettingsView TabView appeared") }
        .sheet(item: $vm.editingAccount) { _ in
            accountSheet
        }
    }

    // MARK: - Accounts tab

    private var accountsTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            List {
                if vm.accounts.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "person.badge.plus")
                            .font(.system(size: 28))
                            .foregroundStyle(.secondary)
                        Text(localization.tr("settings.accounts.empty.title"))
                            .foregroundStyle(.secondary)
                        Text(localization.tr("settings.accounts.empty.subtitle"))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                    .listRowSeparator(.hidden)
                } else {
                    ForEach(vm.accounts) { account in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(account.displayName.isEmpty ? account.email : account.displayName)
                                    .font(.system(size: 13, weight: .medium))
                                Text(account.serverURL)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(account.accountType.displayName)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.15))
                                .clipShape(Capsule())
                            Button {
                                vm.beginEditAccount(account)
                            } label: {
                                Image(systemName: "pencil")
                            }
                            .buttonStyle(.plain)
                            .help(localization.tr("settings.account.sheet.edit"))

                            Button {
                                accountPendingDeletion = account
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                            .help(localization.tr("settings.accounts.remove"))
                        }
                        .padding(.vertical, 4)
                        .contextMenu {
                            Button(role: .destructive) {
                                accountPendingDeletion = account
                            } label: {
                                Label(localization.tr("settings.accounts.remove"), systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                accountPendingDeletion = account
                            } label: {
                                Label(localization.tr("settings.accounts.remove"), systemImage: "trash")
                            }
                        }
                    }
                }
            }

            Divider()

            HStack {
                Button {
                    vm.beginAddAccount()
                } label: {
                    Label(localization.tr("settings.accounts.add"), systemImage: "plus")
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .alert(
            localization.tr("settings.accounts.remove.confirm.title"),
            isPresented: Binding(
                get: { accountPendingDeletion != nil },
                set: { if !$0 { accountPendingDeletion = nil } }
            ),
            presenting: accountPendingDeletion
        ) { account in
            Button(localization.tr("settings.accounts.remove"), role: .destructive) {
                vm.deleteAccount(account)
                accountPendingDeletion = nil
            }
            Button(localization.tr("settings.account.cancel"), role: .cancel) {
                accountPendingDeletion = nil
            }
        } message: { account in
            Text(localization.tr(
                "settings.accounts.remove.confirm.message",
                account.displayName.isEmpty ? account.email : account.displayName
            ))
        }
    }

    // MARK: - Edit / add sheet

    private var accountSheet: some View {
        VStack(spacing: 0) {
            Text(vm.isAddingNew ? localization.tr("settings.account.sheet.add") : localization.tr("settings.account.sheet.edit"))
                .font(.headline)
                .padding()

            Divider()

            if vm.editingAccount != nil {
                AccountSettingsView(
                    vm: vm,
                    account: Binding(
                        get: { vm.editingAccount ?? CalendarAccount(displayName: "", serverURL: "", email: "") },
                        // При закрытии окна editingAccount становится nil, но поля при потере
                        // фокуса успевают закоммитить значение и через этот setter «воскрешают»
                        // пустой аккаунт, из-за чего sheet тут же открывается заново. Игнорируем
                        // запись, если редактирование уже завершено.
                        set: { if vm.editingAccount != nil { vm.editingAccount = $0 } }
                    ),
                    password: $vm.editingPassword,
                    isNew: vm.isAddingNew,
                    onTestConnection: { vm.testConnection(localization: localization) },
                    testResult: vm.testResult,
                    isTesting: vm.isTesting
                )
            }

            Divider()

            HStack {
                Button(localization.tr("settings.account.cancel")) { vm.cancelEditing() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(vm.isAddingNew ? localization.tr("settings.account.add") : localization.tr("settings.account.save")) {
                    vm.saveAccount(localization: localization)
                }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!vm.canSaveAccount)
            }
            .padding()
        }
        .frame(width: 420, height: 380)
        // One alert, not two. Stacking `.alert` modifiers on the same view means SwiftUI
        // presents whichever one it picks and silently drops the other — and the one it drops
        // here would be the only way to approve a login host, leaving sync latched with no way
        // out. Both prompts are mutually exclusive anyway, so they share the modifier.
        .alert(
            securityPromptTitle,
            isPresented: Binding(
                get: { securityPrompt != nil },
                set: { if !$0 { dismissSecurityPrompt() } }
            ),
            presenting: securityPrompt
        ) { prompt in
            switch prompt {
            case .certificate(let pending):
                Button(
                    localization.tr(
                        pending.isReplacingKnownCertificate
                            ? "settings.account.certificate.changed.trust"
                            : "settings.account.certificate.trust"
                    ),
                    // A certificate that changed under a host we already pinned is the one case
                    // here where the safe answer is "no": make the user reach for that button on
                    // purpose.
                    role: pending.isReplacingKnownCertificate ? .destructive : nil
                ) {
                    vm.confirmCertificateTrust(localization: localization)
                }
            case .loginHost:
                // Destructive on purpose. Approving means the account credentials will be handed
                // to a host the server chose, and the safe answer is "no" unless the user
                // recognises it.
                Button(localization.tr("settings.account.login.host.approve"), role: .destructive) {
                    vm.confirmLoginHostApproval(localization: localization)
                }
            }
            Button(localization.tr("settings.account.cancel"), role: .cancel) {
                dismissSecurityPrompt()
            }
        } message: { prompt in
            switch prompt {
            case .certificate(let pending): Text(certificateAlertMessage(for: pending))
            case .loginHost(let pending): Text(loginHostAlertMessage(for: pending))
            }
        }
    }

    /// The security question currently waiting on the user, if any. Certificate first: it is
    /// raised earlier in the connection attempt, so if both were somehow pending it is the one
    /// that has to be answered before the other can even be reached.
    private enum SecurityPrompt: Identifiable {
        case certificate(SettingsViewModel.PendingCertificateTrust)
        case loginHost(SettingsViewModel.PendingLoginHostApproval)

        var id: String {
            switch self {
            case .certificate(let pending): "cert:\(pending.id)"
            case .loginHost(let pending): "loginHost:\(pending.id)"
            }
        }
    }

    private var securityPrompt: SecurityPrompt? {
        if let pending = vm.pendingCertTrust { return .certificate(pending) }
        if let pending = vm.pendingLoginHostApproval { return .loginHost(pending) }
        return nil
    }

    private var securityPromptTitle: String {
        switch securityPrompt {
        case .certificate(let pending):
            return localization.tr(
                pending.isReplacingKnownCertificate
                    ? "settings.account.certificate.changed.title"
                    : "settings.account.certificate.untrusted.title"
            )
        case .loginHost:
            return localization.tr("settings.account.login.host.title")
        case nil:
            return ""
        }
    }

    private func dismissSecurityPrompt() {
        vm.cancelCertificateTrust()
        vm.cancelLoginHostApproval()
    }

    private func loginHostAlertMessage(
        for pending: SettingsViewModel.PendingLoginHostApproval
    ) -> String {
        // The hops are what make the difference visible: a corporate ADFS chain reads as one, and
        // a server quietly pointing the login somewhere else reads as the other.
        let hops = pending.redirectChain.isEmpty
            ? ""
            : pending.redirectChain.joined(separator: "\n") + "\n\n"
        return localization.tr(
            "settings.account.login.host.message",
            pending.configuredHost,
            pending.loginHost,
            hops
        )
    }

    private func certificateAlertMessage(
        for pending: SettingsViewModel.PendingCertificateTrust
    ) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        formatter.locale = localization.locale

        let lines = pending.details?.summaryLines(
            subjectLabel: localization.tr("settings.account.certificate.subject"),
            issuerLabel: localization.tr("settings.account.certificate.issuer"),
            validUntilLabel: localization.tr("settings.account.certificate.valid.until"),
            dateFormatter: formatter
        ) ?? []
        let detailsBlock = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n\n"

        if pending.isReplacingKnownCertificate {
            return localization.tr(
                "settings.account.certificate.changed.message",
                pending.host,
                detailsBlock,
                pending.previousFingerprints.sorted().joined(separator: "\n"),
                pending.fingerprint
            )
        }
        return localization.tr(
            "settings.account.certificate.untrusted.message",
            pending.host,
            detailsBlock,
            pending.fingerprint
        )
    }
}
