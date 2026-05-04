import SwiftUI

/// Form for adding or editing a single Exchange account.
struct AccountSettingsView: View {
    @Binding var account: CalendarAccount
    @Binding var password: String
    var isNew: Bool
    var onTestConnection: () -> Void
    var testResult: String?
    var isTesting: Bool

    var body: some View {
        Form {
            Section("Exchange Server") {
                TextField("Server URL", text: $account.serverURL,
                          prompt: Text("mail.company.com или https://mail.company.com/owa"))
                    .help("Принимается любой формат: mail.company.com, https://mail.company.com или https://mail.company.com/owa")

                TextField("Email", text: $account.email)

                SecureField("Password", text: $password)
            }

            Section("Display") {
                TextField("Account name", text: $account.displayName)
                    .help("Friendly name shown in the accounts list")
            }

            Section {
                HStack {
                    Button(isTesting ? "Testing…" : "Test Connection") {
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
