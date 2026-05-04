import SwiftUI

/// Form for adding or editing a single Exchange account.
struct AccountSettingsView: View {
    @Binding var account: CalendarAccount
    @Binding var password: String
    @EnvironmentObject private var localization: LocalizationService
    var isNew: Bool
    var onTestConnection: () -> Void
    var testResult: String?
    var isTesting: Bool

    var body: some View {
        Form {
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
        .formStyle(.grouped)
    }
}
