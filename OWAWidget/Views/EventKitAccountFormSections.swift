import SwiftUI

/// Calendar picker for an EventKit account.
///
/// There is nothing to authenticate here: the account exists the moment macOS grants calendar
/// access, and configuring it means choosing which of the already-synced calendars to watch.
struct EventKitAccountFormSections: View {
    @ObservedObject var vm: SettingsViewModel
    @Binding var displayName: String
    @EnvironmentObject private var localization: LocalizationService

    var body: some View {
        Section(localization.tr("settings.account.calendars.section")) {
            switch vm.eventKitAccess {
            case .fullAccess:
                calendarList
            case .notDetermined:
                accessRequest
            case .denied, .restricted:
                accessBlocked(message: localization.tr("settings.account.calendars.denied"))
            case .writeOnly:
                accessBlocked(message: localization.tr("settings.account.calendars.writeonly"))
            }

            if let error = vm.eventKitError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }
        }

        Section(localization.tr("settings.account.display.section")) {
            TextField(localization.tr("settings.account.name"), text: $displayName)
                .help(localization.tr("settings.account.name.help"))
        }
    }

    @ViewBuilder
    private var calendarList: some View {
        if vm.eventKitCalendars.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(localization.tr("settings.account.calendars.empty"))
                    .foregroundStyle(.secondary)
                Text(localization.tr("settings.account.calendars.hint"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        } else {
            ForEach(vm.eventKitCalendarGroups, id: \.source) { group in
                VStack(alignment: .leading, spacing: 4) {
                    Text(group.source)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    ForEach(group.calendars) { calendar in
                        Toggle(isOn: binding(for: calendar.identifier)) {
                            Text(calendar.title)
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var accessRequest: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(localization.tr("settings.account.calendars.request.hint"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Button(localization.tr("settings.account.calendars.request")) {
                Task { await vm.requestCalendarAccess() }
            }
            .disabled(vm.isLoadingEventKit)
        }
    }

    private func accessBlocked(message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Button(localization.tr("settings.account.calendars.open.settings")) {
                vm.openCalendarPrivacySettings()
            }
        }
    }

    /// Writes the value it is given rather than flipping the stored one: a write that repeats
    /// the current value — a re-entrant update while the calendar list reloads, say — would
    /// otherwise invert the checkbox instead of leaving it alone.
    private func binding(for identifier: String) -> Binding<Bool> {
        Binding(
            get: { vm.selectedCalendarIdentifiers.contains(identifier) },
            set: { isOn in vm.setCalendar(identifier, selected: isOn) }
        )
    }
}
