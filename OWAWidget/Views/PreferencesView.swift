import SwiftUI

struct PreferencesView: View {
    @ObservedObject var vm: SettingsViewModel
    @EnvironmentObject private var localization: LocalizationService

    private let syncOptions: [(minutes: Int, value: TimeInterval)] = [
        (1, 60),
        (2, 120),
        (5, 300),
        (10, 600),
        (15, 900),
        (30, 1800),
    ]

    private let leadOptions: [(minutes: Int, value: Int)] = [
        (1, 1),
        (2, 2),
        (5, 5),
        (10, 10),
        (15, 15),
        (30, 30),
    ]

    var body: some View {
        Form {
            Section(localization.tr("language.section.title")) {
                Picker(localization.tr("language.picker.title"), selection: $localization.selectedLanguage) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(localization.tr(language.localizationKey)).tag(language)
                    }
                }
                .pickerStyle(.menu)
            }

            Section(localization.tr("preferences.sync.section")) {
                Picker(localization.tr("preferences.sync.interval"), selection: $vm.syncInterval) {
                    ForEach(syncOptions, id: \.value) { opt in
                        Text(localization.minutes(opt.minutes)).tag(opt.value)
                    }
                }
                .pickerStyle(.menu)
            }

            Section(localization.tr("preferences.notifications.section")) {
                Picker(localization.tr("preferences.notifications.style"), selection: $vm.meetingReminderStyle) {
                    ForEach(MeetingReminderStyle.allCases) { style in
                        Text(localization.tr(style.localizationKey)).tag(style)
                    }
                }
                .pickerStyle(.menu)

                Picker(localization.tr("preferences.notifications.remind"), selection: $vm.notificationLeadMinutes) {
                    ForEach(leadOptions, id: \.value) { opt in
                        Text(localization.tr("preferences.notifications.before", localization.minutes(opt.minutes))).tag(opt.value)
                    }
                }
                .pickerStyle(.menu)
            }

            Section {
                Button(localization.tr("preferences.save")) {
                    vm.savePreferences()
                }
            }

            #if DEBUG
            Section("Debug") {
                HStack {
                    Text(localization.tr("preferences.debug.reminder.delay"))
                    Spacer()
                    Text("\(Int(vm.testReminderDelaySeconds))s")
                        .foregroundStyle(.secondary)
                }
                Slider(value: Binding(
                    get: { vm.testReminderDelaySeconds },
                    set: { vm.testReminderDelaySeconds = $0 }
                ), in: 1...15, step: 1)

                Button(localization.tr("preferences.debug.reminder.trigger")) {
                    vm.triggerTestReminderNow()
                }
            }
            #endif
        }
        .formStyle(.grouped)
        .frame(minWidth: 320)
    }
}
