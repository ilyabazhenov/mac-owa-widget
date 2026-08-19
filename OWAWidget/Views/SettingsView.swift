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
                    .disabled(vm.editingAccount?.serverURL.isEmpty == true ||
                              vm.editingAccount?.email.isEmpty == true ||
                              (vm.isAddingNew && vm.editingPassword.isEmpty))
            }
            .padding()
        }
        .frame(width: 420, height: 380)
        .alert(
            certificateAlertTitle,
            isPresented: Binding(
                get: { vm.pendingCertTrust != nil },
                set: { if !$0 { vm.cancelCertificateTrust() } }
            ),
            presenting: vm.pendingCertTrust
        ) { pending in
            Button(
                localization.tr(
                    pending.isReplacingKnownCertificate
                        ? "settings.account.certificate.changed.trust"
                        : "settings.account.certificate.trust"
                ),
                // A certificate that changed under a host we already pinned is the one case here
                // where the safe answer is "no": make the user reach for that button on purpose.
                role: pending.isReplacingKnownCertificate ? .destructive : nil
            ) {
                vm.confirmCertificateTrust(localization: localization)
            }
            Button(localization.tr("settings.account.cancel"), role: .cancel) {
                vm.cancelCertificateTrust()
            }
        } message: { pending in
            Text(certificateAlertMessage(for: pending))
        }
    }

    private var certificateAlertTitle: String {
        localization.tr(
            vm.pendingCertTrust?.isReplacingKnownCertificate == true
                ? "settings.account.certificate.changed.title"
                : "settings.account.certificate.untrusted.title"
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
