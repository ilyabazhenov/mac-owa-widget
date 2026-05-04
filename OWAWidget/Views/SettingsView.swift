import SwiftUI

struct SettingsView: View {
    @StateObject private var vm: SettingsViewModel

    init(calendarService: CalendarService) {
        _vm = StateObject(wrappedValue: SettingsViewModel(calendarService: calendarService))
    }

    var body: some View {
        TabView {
            accountsTab
                .tabItem { Label("Accounts", systemImage: "person.2") }

            PreferencesView(vm: vm)
                .tabItem { Label("Preferences", systemImage: "slider.horizontal.3") }

            AboutView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 480)
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
                        Text("No accounts yet")
                            .foregroundStyle(.secondary)
                        Text("Click + to add your Exchange account")
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
                                Label("Remove", systemImage: "trash")
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
                    Label("Add Account", systemImage: "plus")
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
            Text(vm.isAddingNew ? "Add Account" : "Edit Account")
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
                    onTestConnection: { vm.testConnection() },
                    testResult: vm.testResult,
                    isTesting: vm.isTesting
                )
            }

            Divider()

            HStack {
                Button("Cancel") { vm.editingAccount = nil }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(vm.isAddingNew ? "Add" : "Save") { vm.saveAccount() }
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
