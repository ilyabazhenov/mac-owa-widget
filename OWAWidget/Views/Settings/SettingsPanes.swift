import SwiftUI

// The sections of the Settings window (see `SettingsPane`). Each is a grouped form bound to the
// same `SettingsViewModel`, which applies every change as it is made; mail settings live in
// `MailService` and apply at once too.

private enum SettingsOptions {
    static let syncIntervals: [(minutes: Int, value: TimeInterval)] = [
        (1, 60), (2, 120), (5, 300), (10, 600), (15, 900), (30, 1800),
    ]
    static let reminderLeadMinutes = [1, 2, 5, 10, 15, 30]
    static let colleagueRows = [3, 4, 6, 8]
}

// MARK: - General

struct GeneralSettingsPane: View {
    @ObservedObject var vm: SettingsViewModel
    @EnvironmentObject private var localization: LocalizationService
    @EnvironmentObject private var updateCheck: UpdateCheckService
    @EnvironmentObject private var appearance: AppearanceService

    private func timeZoneLabel(_ option: DisplayTimeZoneOption) -> String {
        "\(localization.tr(option.localizationKey)) · \(option.utcOffsetLabel)"
    }

    var body: some View {
        Form {
            // NOTE: keyboard-shortcut customization UI (KeyboardShortcuts.Recorder) is
            // temporarily disabled — it is the prime suspect for the v1.0.37 crash when opening
            // Settings on macOS Sequoia. The shortcuts themselves are still registered via
            // KeyboardShortcuts.onKeyUp in MenuBarLabelView; they are listed here read-only.

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
                            .font(.app(.footnote))
                            .foregroundStyle(.secondary)
                        Button(localization.tr("preferences.startup.openSettings")) {
                            vm.openLoginItemsSettings()
                        }
                    }
                }
            }

            Section(localization.tr("settings.group.languageTheme")) {
                Picker(localization.tr("language.picker.title"), selection: $localization.selectedLanguage) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(localization.tr(language.localizationKey)).tag(language)
                    }
                }
                .pickerStyle(.menu)
                Picker(localization.tr("appearance.picker.title"), selection: $appearance.selectedTheme) {
                    ForEach(AppTheme.allCases) { theme in
                        Text(localization.tr(theme.localizationKey)).tag(theme)
                    }
                }
                .pickerStyle(.menu)
            }

            Section(localization.tr("preferences.timezone.section")) {
                Picker(localization.tr("preferences.timezone.picker"), selection: $vm.displayTimeZone) {
                    ForEach(DisplayTimeZoneOption.selectable) { option in
                        Text(timeZoneLabel(option)).tag(option)
                    }
                }
                .pickerStyle(.menu)
                Text(localization.tr("preferences.timezone.hint"))
                    .font(.app(.footnote))
                    .foregroundStyle(.secondary)
            }

            // Global, not tied to the popover: they work from any app.
            Section(localization.tr("preferences.shortcuts.section")) {
                Toggle(isOn: $vm.globalJoinHotkeyEnabled) {
                    HStack {
                        Text(localization.tr("preferences.shortcuts.joinMeeting"))
                        Spacer()
                        Text("⌃⌥J").foregroundStyle(.secondary).monospaced()
                    }
                }
                LabeledContent(localization.tr("preferences.shortcuts.createMeeting")) {
                    Text("⌃⌥N").monospaced()
                }
                LabeledContent(localization.tr("preferences.shortcuts.openMail")) {
                    Text("⌃⌥M").monospaced()
                }
                Text(localization.tr("preferences.shortcuts.always.hint"))
                    .font(.app(.footnote))
                    .foregroundStyle(.secondary)
            }

            Section(localization.tr("preferences.updates.section")) {
                SettingsToggle(
                    title: localization.tr("preferences.updates.toggle"),
                    info: localization.tr("preferences.updates.hint"),
                    isOn: $updateCheck.isAutomaticChecksEnabled
                )
                Button(localization.tr("preferences.updates.checkNow")) {
                    Task { await updateCheck.checkNow() }
                }
                .disabled(updateCheck.isChecking)
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

                Button("Show test invitation panel") {
                    vm.presentTestInvitations()
                }

                Button("Force auth block") {
                    vm.debugForceAuthBlock()
                }
                Button("Simulate one auth failure") {
                    vm.debugSimulateAuthFailure()
                }
            }
            #endif
        }
        .formStyle(.grouped)
    }
}

// MARK: - Sync (shown under the accounts list)

struct SyncSettingsSection: View {
    @ObservedObject var vm: SettingsViewModel
    @EnvironmentObject private var localization: LocalizationService

    var body: some View {
        Form {
            Section(localization.tr("preferences.sync.section")) {
                Picker(localization.tr("preferences.sync.interval"), selection: $vm.syncInterval) {
                    ForEach(SettingsOptions.syncIntervals, id: \.value) { option in
                        Text(localization.minutes(option.minutes)).tag(option.value)
                    }
                }
                .pickerStyle(.menu)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }
}

// MARK: - Menu bar and popover

struct MenuBarSettingsPane: View {
    @ObservedObject var vm: SettingsViewModel
    @EnvironmentObject private var localization: LocalizationService

    var body: some View {
        Form {
            Section(localization.tr("preferences.menubar.section")) {
                Picker(localization.tr("preferences.menubar.display"), selection: $vm.menuBarDisplayMode) {
                    Text(localization.tr("preferences.menubar.display.countdown")).tag(MenuBarDisplayMode.countdown)
                    Text(localization.tr("preferences.menubar.display.status")).tag(MenuBarDisplayMode.status)
                    Text(localization.tr("preferences.menubar.display.smart")).tag(MenuBarDisplayMode.smart)
                }
                .pickerStyle(.menu)
                // Someone looking for a counter here is pointed to where it lives.
                Text(localization.tr("preferences.menubar.counters.hint"))
                    .font(.app(.footnote))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section(localization.tr("preferences.popover.section")) {
                Picker(localization.tr("preferences.popover.size"), selection: $vm.popoverSizePreset) {
                    ForEach(PopoverSize.Preset.allCases) { preset in
                        Text(localization.tr(preset.localizationKey)).tag(preset)
                    }
                }
                .pickerStyle(.menu)
                Toggle(
                    localization.tr("preferences.timeline.dimPastMeetings"),
                    isOn: $vm.dimPastMeetingsOnTimeline
                )
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Reminders

struct RemindersSettingsPane: View {
    @ObservedObject var vm: SettingsViewModel
    @EnvironmentObject private var localization: LocalizationService

    var body: some View {
        Form {
            Section(localization.tr("preferences.reminders.group.before")) {
                Picker(localization.tr("preferences.notifications.remind"), selection: $vm.notificationLeadMinutes) {
                    ForEach(SettingsOptions.reminderLeadMinutes, id: \.self) { minutes in
                        Text(localization.tr("preferences.notifications.before", localization.minutes(minutes))).tag(minutes)
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

            Section(localization.tr("preferences.reminders.group.banner")) {
                Picker(localization.tr("preferences.notifications.screen"), selection: $vm.notificationScreenPolicy) {
                    ForEach(NotificationScreenPolicy.allCases) { policy in
                        Text(localization.tr(policy.localizationKey)).tag(policy)
                    }
                }
                .pickerStyle(.menu)

                Picker(localization.tr("preferences.notifications.position"), selection: $vm.notificationPosition) {
                    Section(localization.tr("preferences.notifications.position.group.top")) {
                        ForEach(NotificationPosition.topCases) { position in
                            Text(localization.tr(position.shortLocalizationKey)).tag(position)
                        }
                    }
                    Section(localization.tr("preferences.notifications.position.group.bottom")) {
                        ForEach(NotificationPosition.bottomCases) { position in
                            Text(localization.tr(position.shortLocalizationKey)).tag(position)
                        }
                    }
                }
                .pickerStyle(.menu)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Invitations

struct InvitationsSettingsPane: View {
    @ObservedObject var vm: SettingsViewModel
    @EnvironmentObject private var localization: LocalizationService

    var body: some View {
        Form {
            Section(localization.tr("settings.pane.invitations")) {
                SettingsToggle(
                    title: localization.tr("preferences.invitations.enabled"),
                    info: localization.tr("preferences.invitations.hint"),
                    isOn: $vm.invitationAlertsEnabled
                )
                // Two levels: the popover section needs the feature, the counter needs the section
                // (without it the counter would have nowhere to be cleared from).
                Toggle(
                    localization.tr("preferences.invitations.popoverSection"),
                    isOn: $vm.invitationPopoverSectionEnabled
                )
                .disabled(!vm.invitationAlertsEnabled)
                .padding(.leading, 16)
                Toggle(
                    localization.tr("preferences.invitations.menuBarBadge"),
                    isOn: $vm.invitationMenuBarBadgeEnabled
                )
                .disabled(!vm.invitationAlertsEnabled || !vm.invitationPopoverSectionEnabled)
                .padding(.leading, 32)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Mail

struct MailSettingsPane: View {
    @EnvironmentObject private var mail: MailService

    var body: some View {
        Form {
            MailSettingsSections(mail: mail)
        }
        .formStyle(.grouped)
    }
}

// MARK: - Colleagues

struct ColleaguesSettingsPane: View {
    @ObservedObject var vm: SettingsViewModel
    @EnvironmentObject private var localization: LocalizationService

    var body: some View {
        Form {
            Section(localization.tr("preferences.colleagues.section")) {
                SettingsToggle(
                    title: localization.tr("preferences.colleagues.enabled"),
                    info: localization.tr("preferences.colleagues.hint"),
                    isOn: $vm.colleaguesSectionEnabled
                )
                Toggle(
                    localization.tr("preferences.colleagues.refreshOnOpen"),
                    isOn: $vm.colleaguesRefreshOnPopoverOpen
                )
                .disabled(!vm.colleaguesSectionEnabled)
                .padding(.leading, 16)
                Picker(localization.tr("preferences.colleagues.cache"), selection: $vm.colleaguesCacheMinutes) {
                    ForEach(ColleagueRefreshPolicy.cacheMinuteOptions, id: \.self) { minutes in
                        Text(localization.minutes(minutes)).tag(minutes)
                    }
                }
                .disabled(!vm.colleaguesSectionEnabled)
                .padding(.leading, 16)
                Picker(localization.tr("preferences.colleagues.rows"), selection: $vm.colleaguesRowLimit) {
                    ForEach(SettingsOptions.colleagueRows, id: \.self) { rows in
                        Text("\(rows)").tag(rows)
                    }
                }
                .disabled(!vm.colleaguesSectionEnabled)
                .padding(.leading, 16)
            }
        }
        .formStyle(.grouped)
    }
}
