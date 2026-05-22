import SwiftUI

struct SettingsView: View {
    @StateObject private var vm: SettingsViewModel
    @EnvironmentObject private var localization: LocalizationService

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
                        }
                        .padding(.vertical, 4)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                vm.deleteAccount(account)
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
                        set: { vm.editingAccount = $0 }
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
                Button(localization.tr("settings.account.cancel")) { vm.editingAccount = nil }
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
    }
}
