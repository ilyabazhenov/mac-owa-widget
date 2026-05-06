import SwiftUI

struct PreferencesView: View {
    @ObservedObject var vm: SettingsViewModel
    @EnvironmentObject private var localization: LocalizationService
    @EnvironmentObject private var updateCheck: UpdateCheckService

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
            Section(localization.tr("preferences.startup.section")) {
                Toggle(
                    localization.tr("preferences.startup.launchAtLogin"),
                    isOn: Binding(
                        get: { vm.launchAtLogin },
                        set: { vm.setLaunchAtLogin($0) }
                    )
                )
                if vm.launchAtLoginRequiresApproval {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(localization.tr("preferences.startup.requiresApproval"))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Button(localization.tr("preferences.startup.openSettings")) {
                            vm.openLoginItemsSettings()
                        }
                    }
                }
            }

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

                Picker(localization.tr("preferences.notifications.screen"), selection: $vm.notificationScreenPolicy) {
                    ForEach(NotificationScreenPolicy.allCases) { policy in
                        Text(localization.tr(policy.localizationKey)).tag(policy)
                    }
                }
                .pickerStyle(.menu)

                HStack {
                    Picker(localization.tr("preferences.notifications.sound"), selection: $vm.meetingReminderSound) {
                        ForEach(MeetingReminderSound.allCases) { sound in
                            Text(localization.tr(sound.localizationKey)).tag(sound)
                        }
                    }
                    .pickerStyle(.menu)
                    Button(localization.tr("preferences.notifications.sound.preview")) {
                        vm.previewMeetingReminderSound()
                    }
                    .disabled(vm.meetingReminderSound == .none)
                }
            }

            Section(localization.tr("preferences.engagement.section")) {
                Picker(localization.tr("preferences.engagement.scope"), selection: $vm.meetingEngagementScope) {
                    Text(localization.tr("preferences.engagement.scope.joinableOnly")).tag(MeetingEngagementScope.joinableOnly)
                    Text(localization.tr("preferences.engagement.scope.allEvents")).tag(MeetingEngagementScope.allEvents)
                }
                .pickerStyle(.menu)

                Picker(localization.tr("preferences.engagement.period"), selection: $vm.meetingEngagementDefaultPeriod) {
                    Text(localization.tr("preferences.engagement.period.today")).tag(MeetingEngagementPeriod.today)
                    Text(localization.tr("preferences.engagement.period.7days")).tag(MeetingEngagementPeriod.sevenDays)
                    Text(localization.tr("preferences.engagement.period.30days")).tag(MeetingEngagementPeriod.thirtyDays)
                }
                .pickerStyle(.menu)
            }

            Section(localization.tr("preferences.updates.section")) {
                Toggle(
                    localization.tr("preferences.updates.toggle"),
                    isOn: $updateCheck.isAutomaticChecksEnabled
                )
                Text(localization.tr("preferences.updates.hint"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Button(localization.tr("preferences.updates.checkNow")) {
                    Task { await updateCheck.checkNow() }
                }
                .disabled(updateCheck.isChecking)
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
