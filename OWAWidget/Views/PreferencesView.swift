import SwiftUI

struct PreferencesView: View {
    @ObservedObject var vm: SettingsViewModel
    @EnvironmentObject private var localization: LocalizationService
    @EnvironmentObject private var updateCheck: UpdateCheckService
    @EnvironmentObject private var appearance: AppearanceService

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

    private func timeZoneLabel(_ option: DisplayTimeZoneOption) -> String {
        "\(localization.tr(option.localizationKey)) · \(option.utcOffsetLabel)"
    }

    var body: some View {
        Form {
            // NOTE: keyboard-shortcut customization UI (KeyboardShortcuts.Recorder)
            // is temporarily disabled — it is the prime suspect for the v1.0.37 crash
            // when opening Settings on macOS Sequoia. The shortcut itself is still
            // registered via KeyboardShortcuts.onKeyUp in MenuBarLabelView with the
            // default Ctrl+Opt+N; users just can't rebind it through the UI right now.
            // Localization keys preferences.shortcuts.section / .createMeeting kept
            // so we can restore the UI once the root cause is confirmed.

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

            Section(localization.tr("appearance.section.title")) {
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
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section(localization.tr("preferences.sync.section")) {
                Picker(localization.tr("preferences.sync.interval"), selection: $vm.syncInterval) {
                    ForEach(syncOptions, id: \.value) { opt in
                        Text(localization.minutes(opt.minutes)).tag(opt.value)
                    }
                }
                .pickerStyle(.menu)
            }

            Section(localization.tr("preferences.menubar.section")) {
                Picker(localization.tr("preferences.menubar.display"), selection: $vm.menuBarDisplayMode) {
                    Text(localization.tr("preferences.menubar.display.countdown")).tag(MenuBarDisplayMode.countdown)
                    Text(localization.tr("preferences.menubar.display.status")).tag(MenuBarDisplayMode.status)
                    Text(localization.tr("preferences.menubar.display.smart")).tag(MenuBarDisplayMode.smart)
                }
                .pickerStyle(.menu)
            }

            Section(localization.tr("preferences.popover.section")) {
                Picker(localization.tr("preferences.popover.size"), selection: $vm.popoverSizePreset) {
                    ForEach(PopoverSize.Preset.allCases) { preset in
                        Text(localization.tr(preset.localizationKey)).tag(preset)
                    }
                }
                .pickerStyle(.menu)
            }

            Section(localization.tr("preferences.shortcuts.section")) {
                Toggle(
                    localization.tr("preferences.shortcuts.joinMeeting"),
                    isOn: $vm.globalJoinHotkeyEnabled
                )
                Text(localization.tr("preferences.shortcuts.joinMeeting.hint", "Ctrl+Option+J"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section(localization.tr("preferences.timeline.section")) {
                Toggle(
                    localization.tr("preferences.timeline.dimPastMeetings"),
                    isOn: $vm.dimPastMeetingsOnTimeline
                )
            }

            Section(localization.tr("preferences.notifications.section")) {
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
        .frame(minWidth: 320)
        .onAppear {
            DiagnosticLog.event("PreferencesView Form appeared")
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Divider()
            HStack {
                Spacer()
                Button(localization.tr("preferences.save")) {
                    vm.savePreferences()
                }
                .keyboardShortcut("s", modifiers: [.command])
                .buttonStyle(.borderedProminent)
                .disabled(!vm.hasUnsavedChanges)
            }
            .padding(12)
            .background(.regularMaterial)
        }
    }
}
