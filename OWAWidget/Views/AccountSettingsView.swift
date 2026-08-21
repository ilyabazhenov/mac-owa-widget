import SwiftUI

/// Form for adding or editing a single calendar account. The body depends on the account type:
/// server accounts are configured by address and credentials, EventKit accounts by picking from
/// the calendars macOS already syncs.
struct AccountSettingsView: View {
    @ObservedObject var vm: SettingsViewModel
    @Binding var account: CalendarAccount
    @Binding var password: String
    @EnvironmentObject private var localization: LocalizationService
    var isNew: Bool
    var onTestConnection: () -> Void
    var testResult: String?
    var isTesting: Bool

    var body: some View {
        Form {
            // The type is fixed once an account exists: switching it would strand either the
            // stored password or the calendar selection.
            if isNew {
                Section(localization.tr("settings.account.type.section")) {
                    Picker(localization.tr("settings.account.type"), selection: typeBinding) {
                        ForEach(Self.offeredTypes, id: \.self) { type in
                            Text(type.displayName).tag(type)
                        }
                    }
                    .pickerStyle(.radioGroup)
                }
            }

            switch account.accountType {
            case .owa, .googleCalendar:
                exchangeSections
            case .eventKit:
                EventKitAccountFormSections(vm: vm, displayName: $account.displayName)
            }
        }
        .formStyle(.grouped)
    }

    /// Google Calendar has an enum case reserved for a direct API integration that does not exist
    /// yet, so it is not offered here — its calendars arrive through the EventKit account instead.
    private static let offeredTypes: [AccountType] = [.owa, .eventKit]

    private var typeBinding: Binding<AccountType> {
        Binding(
            get: { account.accountType },
            set: { vm.changeEditingAccountType(to: $0) }
        )
    }

    @ViewBuilder
    private var exchangeSections: some View {
        Section(localization.tr("settings.account.exchange.section")) {
            TextField(localization.tr("settings.account.server.url"), text: $account.serverURL,
                      prompt: Text(localization.tr("settings.account.server.prompt")))
                .help(localization.tr("settings.account.server.help"))

            TextField(localization.tr("settings.account.email"), text: $account.email)

            SecureField(localization.tr("settings.account.password"), text: $password)
        }

        Section(localization.tr("settings.account.display.section")) {
            TextField(localization.tr("settings.account.name"), text: $account.displayName)
                .help(localization.tr("settings.account.name.help"))
        }

        Section {
            HStack {
                Button(isTesting ? localization.tr("settings.account.testing") : localization.tr("settings.account.test")) {
                    onTestConnection()
                }
                .disabled(isTesting || account.serverURL.isEmpty || account.email.isEmpty || password.isEmpty)

                if let result = testResult {
                    Text(result)
                        .font(.system(size: 11))
                        .foregroundStyle(result.hasPrefix("✓") ? .green : .red)
                }
            }
        }
    }
}
