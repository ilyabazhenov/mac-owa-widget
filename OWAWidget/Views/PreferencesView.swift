import SwiftUI

struct PreferencesView: View {
    @ObservedObject var vm: SettingsViewModel

    private let syncOptions: [(label: String, value: TimeInterval)] = [
        ("1 minute", 60),
        ("2 minutes", 120),
        ("5 minutes", 300),
        ("10 minutes", 600),
        ("15 minutes", 900),
        ("30 minutes", 1800),
    ]

    private let leadOptions: [(label: String, value: Int)] = [
        ("1 minute", 1),
        ("2 minutes", 2),
        ("5 minutes", 5),
        ("10 minutes", 10),
        ("15 minutes", 15),
        ("30 minutes", 30),
    ]

    var body: some View {
        Form {
            Section("Sync") {
                Picker("Sync interval", selection: $vm.syncInterval) {
                    ForEach(syncOptions, id: \.value) { opt in
                        Text(opt.label).tag(opt.value)
                    }
                }
                .pickerStyle(.menu)
            }

            Section("Notifications") {
                Picker("Remind me", selection: $vm.notificationLeadMinutes) {
                    ForEach(leadOptions, id: \.value) { opt in
                        Text(opt.label + " before").tag(opt.value)
                    }
                }
                .pickerStyle(.menu)
            }

            Section {
                Button("Save Preferences") {
                    vm.savePreferences()
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 320)
    }
}
