import SwiftUI
import AppKit

private struct SearchFieldHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 36
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

enum SlotViewMode: String, CaseIterable {
    case grid, list, heatmap

    var iconName: String {
        switch self {
        case .grid:    return "square.grid.3x2"
        case .list:    return "list.bullet"
        case .heatmap: return "thermometer.medium"
        }
    }

    var localizationKey: String {
        switch self {
        case .grid:    return "create.meeting.view.grid"
        case .list:    return "create.meeting.view.list"
        case .heatmap: return "create.meeting.view.heatmap"
        }
    }
}

struct CreateMeetingView: View {
    @EnvironmentObject private var localization: LocalizationService
    @StateObject private var vm: CreateMeetingViewModel
    @State private var requiredFieldHeight: CGFloat = 36
    @State private var optionalFieldHeight: CGFloat = 36
    @State private var slotViewMode: SlotViewMode = .grid

    init(calendarService: CalendarService, accountID: UUID) {
        _vm = StateObject(wrappedValue: CreateMeetingViewModel(
            calendarService: calendarService,
            accountID: accountID
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                // Left column: meeting details + frequent contacts
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 16) {
                        attendeesField
                        durationField
                        titleField
                        agendaField
                    }
                    .padding(20)

                    if !vm.suggestedAttendees.isEmpty {
                        Divider()
                        frequentContactsGrid
                    } else {
                        Spacer()
                    }
                }
                .frame(width: 320)

                Divider()

                // Right column: slot selection
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        slotsSection
                    }
                    .padding(20)
                }
                .frame(width: 580)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            }
            bottomBar
        }
        .frame(width: 900)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Title & agenda

    private var titleField: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel(localization.tr("create.meeting.title.label"))
            TextField(localization.tr("create.meeting.title.placeholder"), text: $vm.draft.title, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .lineLimit(1...3)
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
                .frame(minHeight: 64, alignment: .topLeading)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                )
        }
    }

    private var agendaField: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel(localization.tr("create.meeting.agenda.label"))
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor))
                if vm.draft.agenda.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(localization.tr("create.meeting.agenda.placeholder"))
                        .font(.system(size: 13))
                        .foregroundStyle(Color(nsColor: .placeholderTextColor))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 12)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $vm.draft.agenda)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 4)
            }
            .frame(minHeight: 100, maxHeight: 200, alignment: .topLeading)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
        }
    }

    // MARK: - Attendees

    private var attendeesField: some View {
        VStack(alignment: .leading, spacing: 14) {
            attendeeGroup(
                title: localization.tr("create.meeting.attendees.required"),
                placeholder: localization.tr("create.meeting.attendees.required.placeholder"),
                kind: .required,
                list: vm.draft.requiredAttendees
            )
            .zIndex(vm.focusedSearchKind == .required ? 2 : 1)

            attendeeGroup(
                title: localization.tr("create.meeting.attendees.optional"),
                placeholder: localization.tr("create.meeting.attendees.optional.placeholder"),
                kind: .optional,
                list: vm.draft.optionalAttendees
            )
            .zIndex(vm.focusedSearchKind == .optional ? 2 : 1)
        }
        .zIndex(1)
    }

    private func attendeeGroup(title: String, placeholder: String, kind: AttendeeKind, list: [ResolvedAttendee]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel(title)
            AttendeeSearchField(vm: vm, kind: kind, placeholder: placeholder)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: SearchFieldHeightKey.self, value: geo.size.height)
                    }
                )
                .onPreferenceChange(SearchFieldHeightKey.self) { newHeight in
                    if kind == .required { requiredFieldHeight = newHeight }
                    else { optionalFieldHeight = newHeight }
                }
                .overlay(alignment: .topLeading) {
                    if vm.showDropdown(for: kind) {
                        AttendeeDropdown(vm: vm, kind: kind)
                            .offset(y: (kind == .required ? requiredFieldHeight : optionalFieldHeight) + 4)
                    }
                }
            if !list.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(list) { attendee in
                        AttendeeChipView(
                            attendee: attendee,
                            kind: kind,
                            toggleHint: localization.tr(kind == .required
                                ? "create.meeting.attendees.make.optional"
                                : "create.meeting.attendees.make.required"),
                            onToggleKind: { vm.toggleAttendeeKind(attendee) },
                            onRemove: { vm.removeAttendee(attendee) }
                        )
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    // MARK: - Duration

    private var durationField: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel(localization.tr("create.meeting.duration.label"))
            Picker("", selection: $vm.selectedDuration) {
                ForEach(MeetingDurationOption.allCases, id: \.self) { opt in
                    Text(localization.tr(opt.localizationKey)).tag(opt)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Frequent contacts grid

    private var frequentContactsGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel(localization.tr("create.meeting.recent.label"))
                .padding(.horizontal, 20)

            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
                    spacing: 8
                ) {
                    ForEach(vm.suggestedAttendees) { attendee in
                        let isAdded = vm.draft.allAttendees.contains(attendee)
                        FrequentContactCard(attendee: attendee, isAdded: isAdded) {
                            if isAdded {
                                vm.removeAttendee(attendee)
                            } else {
                                vm.addAttendee(attendee)
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }
        }
        .padding(.top, 14)
    }

    // MARK: - Slots (right column)

    @ViewBuilder
    private var slotsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            weekNavigator
            slotsContent
        }
    }

    /// Контент под навигатором: либо layout с фиксированной высотой сетки слотов и подсказками по содержимому,
    /// либо placeholder (loading / idle).
    @ViewBuilder
    private var slotsContent: some View {
        if vm.isLoadingSlots {
            placeholderContainer {
                ProgressView()
            }
        } else if !vm.slotsSearched {
            placeholderContainer {
                VStack(spacing: 10) {
                    Image(systemName: "calendar.badge.clock")
                        .font(.system(size: 28))
                        .foregroundStyle(.quaternary)
                    Text(localization.tr("create.meeting.slots.hint"))
                        .font(.system(size: 12))
                        .foregroundStyle(.quaternary)
                        .multilineTextAlignment(.center)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 14) {
                suggestionsBlock

                HStack(spacing: 8) {
                    sectionLabel(localization.tr("create.meeting.available.slots"))
                    Spacer()
                    viewModePicker
                    TimeZoneBadge()
                }

                slotViewContainer
            }
        }
    }

    /// Высота — `suggestions + header + slotView` (плюс gap-ы) — чтобы placeholder занимал
    /// столько же, сколько занимал бы полноценный layout.
    private func placeholderContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        let totalHeight = MeetingSlotsLayout.suggestionsPlaceholderRegionHeight + 14 + 30 + 14 + MeetingSlotsLayout.slotViewHeight
        return VStack {
            Spacer()
            content()
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .frame(height: totalHeight)
    }

    /// Smart Suggestions: with slots, height follows content (no tall empty band). Empty state uses a compact fixed band.
    @ViewBuilder
    private var suggestionsBlock: some View {
        if vm.freeSlots.isEmpty {
            noSlotsEmptyState
        } else {
            SlotSuggestionsView(
                suggestions: SlotRanker.topPicks(from: vm.freeSlots),
                selectedSlotID: $vm.selectedSlotID
            )
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var noSlotsEmptyState: some View {
        VStack(spacing: 12) {
            VStack(spacing: 6) {
                Image(systemName: "calendar.badge.exclamationmark")
                    .font(.system(size: 22))
                    .foregroundStyle(.tertiary)
                Text(localization.tr("create.meeting.no.slots"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 8) {
                Button {
                    vm.shiftSelectedWeek(by: 1)
                } label: {
                    HStack(spacing: 3) {
                        Text(localization.tr("create.meeting.no.slots.next.week"))
                        Image(systemName: "chevron.right")
                    }
                    .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                if vm.draft.durationMinutes > 30 {
                    Button {
                        vm.selectedDuration = .min30
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "clock")
                            Text(localization.tr("create.meeting.no.slots.shorter"))
                        }
                        .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: MeetingSlotsLayout.suggestionsPlaceholderRegionHeight, alignment: .center)
    }

    /// Slot view с фиксированной высотой; list прокручивается внутри.
    @ViewBuilder
    private var slotViewContainer: some View {
        switch slotViewMode {
        case .grid:
            WeekGridSlotView(
                slots: vm.freeSlots,
                selectedSlotID: $vm.selectedSlotID,
                gridWeekInterval: vm.draft.slotGridWeekInterval()
            )
            .frame(height: MeetingSlotsLayout.slotViewHeight, alignment: .top)
        case .list:
            ScrollView {
                SlotListView(
                    slots: vm.freeSlots,
                    selectedSlotID: $vm.selectedSlotID
                )
                .padding(.bottom, 8)
            }
            .frame(height: MeetingSlotsLayout.slotViewHeight)
        case .heatmap:
            WeekGridSlotView(
                slots: vm.freeSlots,
                selectedSlotID: $vm.selectedSlotID,
                gridWeekInterval: vm.draft.slotGridWeekInterval(),
                coloring: .heatmap
            )
            .frame(height: MeetingSlotsLayout.slotViewHeight, alignment: .top)
        }
    }

    private var viewModePicker: some View {
        Picker("", selection: $slotViewMode) {
            ForEach(SlotViewMode.allCases, id: \.self) { mode in
                Image(systemName: mode.iconName).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 120)
        .help(localization.tr(slotViewMode.localizationKey))
    }

    // MARK: - Week navigator

    private var weekNavigator: some View {
        HStack(spacing: 10) {
            navigatorButton(systemName: "chevron.left") {
                vm.shiftSelectedWeek(by: -1)
            }
            .help(localization.tr("create.meeting.week.previous"))

            VStack(spacing: 1) {
                Text(currentWeekLabel)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(nsColor: .labelColor))
                Text(vm.isOnCurrentWeek
                     ? localization.tr("create.meeting.week.current")
                     : weekRelativeLabel)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .center)

            if !vm.isOnCurrentWeek {
                Button {
                    vm.resetToCurrentWeek()
                } label: {
                    Text(localization.tr("create.meeting.week.today"))
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .fill(Color.accentColor.opacity(0.12))
                        )
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .help(localization.tr("create.meeting.week.today.hint"))
            }

            navigatorButton(systemName: "chevron.right") {
                vm.shiftSelectedWeek(by: 1)
            }
            .help(localization.tr("create.meeting.week.next"))

            if !vm.draft.requiredAttendees.isEmpty {
                Button {
                    Task { await vm.findSlots() }
                } label: {
                    Group {
                        if vm.isLoadingSlots {
                            ProgressView().scaleEffect(0.65)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Color(nsColor: .labelColor))
                        }
                    }
                    .frame(width: 24, height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color(nsColor: .controlColor))
                    )
                }
                .buttonStyle(.plain)
                .disabled(vm.isLoadingSlots)
                .help(localization.tr("create.meeting.refresh.slots"))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
    }

    private func navigatorButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color(nsColor: .labelColor))
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color(nsColor: .controlColor))
                )
        }
        .buttonStyle(.plain)
    }

    /// «12 – 16 мая 2026» (один месяц/год) / «28 апр – 2 мая 2026» (разные месяцы)
    /// / «30 дек 2026 – 3 янв 2027» (разные годы).
    private var currentWeekLabel: String {
        let cal = MeetingDraft.weekCalendar
        let monday = cal.startOfDay(for: vm.draft.selectedWeekStart)
        guard let friday = cal.date(byAdding: .day, value: 4, to: monday) else {
            return Self.fullDateFmt.string(from: monday)
        }
        let monYear = cal.component(.year, from: monday)
        let friYear = cal.component(.year, from: friday)
        let monMonth = cal.component(.month, from: monday)
        let friMonth = cal.component(.month, from: friday)

        if monYear != friYear {
            return "\(Self.fullDateFmt.string(from: monday)) – \(Self.fullDateFmt.string(from: friday))"
        } else if monMonth != friMonth {
            return "\(Self.dayMonthFmt.string(from: monday)) – \(Self.fullDateFmt.string(from: friday))"
        } else {
            return "\(Self.dayFmt.string(from: monday)) – \(Self.fullDateFmt.string(from: friday))"
        }
    }

    /// «Через 2 недели» / «2 недели назад» — относительный лейбл, если не текущая неделя.
    private var weekRelativeLabel: String {
        let cal = MeetingDraft.weekCalendar
        let todayMonday = MeetingDraft.mondayOfWeek(containing: Date())
        let selectedMonday = cal.startOfDay(for: vm.draft.selectedWeekStart)
        let diff = cal.dateComponents([.day], from: todayMonday, to: selectedMonday).day ?? 0
        let weeks = diff / 7
        if weeks == 0 { return localization.tr("create.meeting.week.current") }
        if weeks == 1 { return localization.tr("create.meeting.week.next.relative") }
        if weeks == -1 { return localization.tr("create.meeting.week.previous.relative") }
        if weeks > 0 {
            return String(format: localization.tr("create.meeting.week.in.n"), weeks)
        }
        return String(format: localization.tr("create.meeting.week.n.ago"), -weeks)
    }

    private static let dayFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d"
        f.timeZone = AppTimeZone.zone
        return f
    }()

    private static let dayMonthFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM"
        f.timeZone = AppTimeZone.zone
        return f
    }()

    private static let fullDateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM yyyy"
        f.timeZone = AppTimeZone.zone
        return f
    }()

    // MARK: - Bottom bar

    private var bottomBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                if let success = vm.successMessage {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text(localization.tr(success))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                } else if let error = vm.errorMessage {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }

                Spacer()

                Button {
                    Task { await vm.createMeeting() }
                } label: {
                    HStack(spacing: 6) {
                        if vm.isCreating {
                            ProgressView().scaleEffect(0.7).frame(width: 14, height: 14)
                        }
                        Text(localization.tr("create.meeting.create"))
                            .font(.system(size: 13, weight: .medium))
                        if !vm.isCreating {
                            Image(systemName: "arrow.right")
                                .font(.system(size: 11, weight: .semibold))
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!vm.canCreate)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .tracking(0.3)
    }
}

// MARK: - Attendee dropdown (scrollable, capped height)

private struct AttendeeDropdown: View {
    @ObservedObject var vm: CreateMeetingViewModel
    let kind: AttendeeKind

    private static let rowHeight: CGFloat = 50
    private static let maxRows = 5

    private var results: [ResolvedAttendee] { vm.results(for: kind) }

    /// As an overlay child, SwiftUI proposes the parent (search field) height to us — too small for content.
    /// Compute an explicit height instead so the dropdown sizes to its rows (and scrolls only when needed).
    private var computedHeight: CGFloat {
        let visibleRows = min(results.count, Self.maxRows)
        return CGFloat(visibleRows) * Self.rowHeight
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(results) { attendee in
                    DropdownRowView(attendee: attendee) {
                        vm.addAttendee(attendee, kind: kind)
                    }
                    if attendee.id != results.last?.id {
                        Divider().padding(.horizontal, 10)
                    }
                }
            }
        }
        .frame(height: computedHeight)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.1), radius: 8, x: 0, y: 4)
    }
}

private struct DropdownRowView: View {
    let attendee: ResolvedAttendee
    let onSelect: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                InitialsAvatar(name: attendee.displayName, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(attendee.displayName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color(nsColor: .labelColor))
                        .lineLimit(1)
                    if let title = attendee.jobTitle {
                        Text(title)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Text(attendee.email)
                        .font(.system(size: 10))
                        .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(isHovered ? Color(nsColor: .selectedControlColor).opacity(0.5) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Attendee chip

private struct AttendeeChipView: View {
    let attendee: ResolvedAttendee
    let kind: AttendeeKind
    let toggleHint: String
    let onToggleKind: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            InitialsAvatar(name: attendee.displayName, size: 18)
            Text(attendee.displayName.components(separatedBy: " ").prefix(2).joined(separator: " "))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(kind == .required ? .primary : .secondary)
                .lineLimit(1)
            Button(action: onToggleKind) {
                Image(systemName: kind == .required
                      ? "person.fill.checkmark"
                      : "person.crop.circle.badge.questionmark")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(toggleHint)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 4)
        .padding(.trailing, 6)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(Color(nsColor: .controlColor).opacity(kind == .required ? 1.0 : 0.55))
        )
        .overlay(
            Capsule()
                .stroke(
                    Color(nsColor: .separatorColor),
                    style: StrokeStyle(
                        lineWidth: kind == .required ? 0.5 : 1.0,
                        dash: kind == .optional ? [3, 2] : []
                    )
                )
        )
    }
}

// MARK: - Frequent contact card

private struct FrequentContactCard: View {
    let attendee: ResolvedAttendee
    let isAdded: Bool
    let onTap: () -> Void
    @State private var isHovered = false

    private var firstName: String {
        attendee.displayName.components(separatedBy: " ").first ?? attendee.displayName
    }
    private var lastName: String {
        let parts = attendee.displayName.components(separatedBy: " ")
        return parts.dropFirst().first ?? ""
    }

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                InitialsAvatar(name: attendee.displayName, size: 40)
                if isAdded {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.white, Color.accentColor)
                        .background(Circle().fill(Color.accentColor).frame(width: 12, height: 12))
                        .offset(x: 4, y: 4)
                }
            }
            VStack(spacing: 1) {
                Text(lastName.isEmpty ? firstName : lastName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color(nsColor: .labelColor))
                    .lineLimit(1)
                Text(firstName)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isAdded
                    ? Color.accentColor.opacity(0.08)
                    : (isHovered ? Color(nsColor: .controlColor) : Color.clear)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isAdded ? Color.accentColor.opacity(0.3) : Color.clear, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture { onTap() }
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .animation(.easeInOut(duration: 0.15), value: isAdded)
    }
}

// MARK: - Week grid slot picker

/// One grid row = one 30-minute free-busy step (matches `MeetingFreeSlotCalculator` interval).
private enum MeetingSlotGridMetrics {
    static let rowHeight: CGFloat = 24
    static let timeColumnWidth: CGFloat = 44
    static let headerHeight: CGFloat = 28
    /// 18 строк × rowHeight + шапка + вертикальные паддинги — то же, что выдаёт `WeekGridSlotView.body`.
    static var totalHeight: CGFloat { headerHeight + rowHeight * 18 + 8 }
}

/// Reserved heights for the right column: slot grid stays fixed; suggestions use intrinsic height when slots exist
/// (week changes may slightly resize the suggestions band when the pick count changes).
private enum MeetingSlotsLayout {
    /// Height budget for loading/idle placeholder and for the «no slots» empty state (compact, no large blank strip).
    static let suggestionsPlaceholderRegionHeight: CGFloat = 112
    static var slotViewHeight: CGFloat { MeetingSlotGridMetrics.totalHeight }
}

private struct MeetingSlotGridLineOverlay: ViewModifier {
    var leading = false
    var top = false
    var trailing = true
    var bottom = true
    /// Full-hour horizontal (e.g. 10:00); half-hour rows use a softer line.
    var topIsMajor = false
    var bottomIsMajor = false

    private var verticalStroke: Color {
        Color(nsColor: .separatorColor).opacity(0.45)
    }

    private func horizontalStroke(isMajor: Bool) -> Color {
        Color(nsColor: .separatorColor).opacity(isMajor ? 0.62 : 0.22)
    }

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if top {
                    Rectangle()
                        .fill(horizontalStroke(isMajor: topIsMajor))
                        .frame(height: 1)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .leading) {
                if leading {
                    Rectangle()
                        .fill(verticalStroke)
                        .frame(width: 1)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottom) {
                if bottom {
                    Rectangle()
                        .fill(horizontalStroke(isMajor: bottomIsMajor))
                        .frame(height: 1)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .trailing) {
                if trailing {
                    Rectangle()
                        .fill(verticalStroke)
                        .frame(width: 1)
                        .allowsHitTesting(false)
                }
            }
    }
}

private extension View {
    func meetingSlotGridLines(
        leading: Bool = false,
        top: Bool = false,
        trailing: Bool = true,
        bottom: Bool = true,
        topIsMajor: Bool = false,
        bottomIsMajor: Bool = false
    ) -> some View {
        modifier(
            MeetingSlotGridLineOverlay(
                leading: leading,
                top: top,
                trailing: trailing,
                bottom: bottom,
                topIsMajor: topIsMajor,
                bottomIsMajor: bottomIsMajor
            )
        )
    }
}

enum SlotCellColoring {
    /// Бинарная окраска: accent для свободных, без градации.
    case accent
    /// Градиент по `FreeSlot.score`: чем выше score (раньше в дне) — тем насыщеннее.
    case heatmap
}

struct WeekGridSlotView: View {
    private typealias TimeKey = Int
    private typealias DayKey = Date

    private struct GridData {
        let days: [DayKey]
        let lookup: [DayKey: [TimeKey: FreeSlot]]
    }

    let slots: [FreeSlot]
    @Binding var selectedSlotID: UUID?
    let gridWeekInterval: DateInterval
    var coloring: SlotCellColoring = .accent

    private static let timeRows: [TimeKey] = Array(stride(from: 540, to: 1080, by: 30))

    private static let weekdayFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE"
        f.timeZone = AppTimeZone.zone
        return f
    }()

    private static let dayNumFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d"
        f.timeZone = AppTimeZone.zone
        return f
    }()

    private var gridData: GridData {
        let cal = AppTimeZone.calendar
        let order = gridWeekInterval.weekdayColumnStartDates(calendar: cal)
        var lookup: [DayKey: [TimeKey: FreeSlot]] = [:]
        for day in order {
            for timeKey in Self.timeRows {
                if let slot = Self.slotCoveringRow(slots: slots, day: day, timeKey: timeKey, calendar: cal) {
                    if lookup[day] == nil { lookup[day] = [:] }
                    lookup[day]?[timeKey] = slot
                }
            }
        }
        return GridData(days: order, lookup: lookup)
    }

    /// Half-open row `[rowStart, rowEnd)` overlaps slot `[slot.start, slot.end)`.
    private static func slotCoveringRow(
        slots: [FreeSlot],
        day: DayKey,
        timeKey: TimeKey,
        calendar cal: Calendar
    ) -> FreeSlot? {
        guard let rowStart = cal.date(bySettingHour: timeKey / 60, minute: timeKey % 60, second: 0, of: day),
              cal.startOfDay(for: rowStart) == day
        else { return nil }
        let rowEnd = cal.date(byAdding: .minute, value: 30, to: rowStart) ?? rowStart.addingTimeInterval(30 * 60)
        return slots.first { slot in
            cal.startOfDay(for: slot.start) == day && slot.start < rowEnd && slot.end > rowStart
        }
    }

    private func timeLabel(_ key: TimeKey) -> String {
        String(format: "%02d:%02d", key / 60, key % 60)
    }

    private func columnHeader(for day: DayKey) -> some View {
        VStack(spacing: 1) {
            Text(Self.weekdayFmt.string(from: day).capitalized)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Text(Self.dayNumFmt.string(from: day))
                .font(.system(size: 12, weight: .semibold))
        }
        .frame(maxWidth: .infinity)
    }

    var body: some View {
        let data = gridData
        let topEdge = Color(nsColor: .separatorColor).opacity(0.62)
        Grid(horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                Color.clear
                    .frame(minWidth: MeetingSlotGridMetrics.timeColumnWidth, maxWidth: MeetingSlotGridMetrics.timeColumnWidth, minHeight: 28)
                    .meetingSlotGridLines(leading: true, trailing: true, bottom: true, bottomIsMajor: true)
                ForEach(data.days, id: \.self) { day in
                    columnHeader(for: day)
                        .padding(.vertical, 4)
                        .meetingSlotGridLines(trailing: true, bottom: true, bottomIsMajor: true)
                }
            }
            ForEach(Self.timeRows, id: \.self) { timeKey in
                let rowEndsOnHour = (timeKey + 30) % 60 == 0
                GridRow(alignment: .top) {
                    Text(timeLabel(timeKey))
                        .font(.system(size: timeKey % 60 == 0 ? 9 : 8, weight: timeKey % 60 == 0 ? .medium : .regular))
                        .foregroundStyle(timeKey % 60 == 0 ? Color.secondary : Color(nsColor: .tertiaryLabelColor))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                        .padding(.trailing, 4)
                        .frame(width: MeetingSlotGridMetrics.timeColumnWidth, height: MeetingSlotGridMetrics.rowHeight)
                        .gridColumnAlignment(.trailing)
                        .meetingSlotGridLines(leading: true, trailing: true, bottom: true, bottomIsMajor: rowEndsOnHour)
                    ForEach(data.days, id: \.self) { day in
                        let slot = data.lookup[day]?[timeKey]
                        SlotCell(
                            slot: slot,
                            isSelected: slot.map { $0.id == selectedSlotID } == true,
                            coloring: coloring
                        ) {
                            if let slot { selectedSlotID = slot.id }
                        }
                        .frame(maxWidth: .infinity, minHeight: MeetingSlotGridMetrics.rowHeight, maxHeight: MeetingSlotGridMetrics.rowHeight)
                        .meetingSlotGridLines(trailing: true, bottom: true, bottomIsMajor: rowEndsOnHour)
                    }
                }
            }
        }
        .overlay(alignment: .top) {
            Rectangle()
                .fill(topEdge)
                .frame(height: 1)
                .allowsHitTesting(false)
        }
        .padding(.vertical, 4)
    }
}

private struct SlotCell: View {
    let slot: FreeSlot?
    let isSelected: Bool
    let coloring: SlotCellColoring
    let onTap: () -> Void
    @State private var isHovered = false

    private var bg: Color {
        guard let slot else { return .clear }
        if isSelected { return Color.accentColor }
        switch coloring {
        case .accent:
            return Color.accentColor.opacity(isHovered ? 0.22 : 0.12)
        case .heatmap:
            // hue 0.10 (warm orange) → 0.34 (green) by score
            let hue = 0.10 + slot.score * 0.24
            let base = Color(hue: hue, saturation: 0.65, brightness: 0.88)
            return base.opacity(isHovered ? 1.0 : 0.85)
        }
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5).fill(bg)
            if isSelected, slot != nil {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .padding(.horizontal, 2)
        .frame(maxWidth: .infinity)
        .frame(height: MeetingSlotGridMetrics.rowHeight)
        .contentShape(Rectangle())
        .onTapGesture {
            if slot != nil { onTap() }
        }
        .onHover { isHovered = $0 && slot != nil }
        .animation(.easeInOut(duration: 0.12), value: isSelected)
        .animation(.easeInOut(duration: 0.12), value: isHovered)
    }
}

// MARK: - Initials avatar

struct InitialsAvatar: View {
    let name: String
    let size: CGFloat

    private var initials: String {
        let parts = name.components(separatedBy: " ").filter { !$0.isEmpty }
        let letters = parts.prefix(2).compactMap { $0.first.map { String($0) } }
        return letters.joined().uppercased()
    }

    private var color: Color {
        let colors: [Color] = [.blue, .purple, .green, .orange, .pink, .teal, .indigo]
        let index = abs(name.hashValue) % colors.count
        return colors[index]
    }

    var body: some View {
        ZStack {
            Circle().fill(color.opacity(0.18))
            Text(initials)
                .font(.system(size: size * 0.38, weight: .semibold))
                .foregroundStyle(color)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Flow layout

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? 300
        var height: CGFloat = 0
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth + size.width > maxWidth, rowWidth > 0 {
                height += rowHeight + spacing
                rowWidth = 0; rowHeight = 0
            }
            rowWidth += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth, height: max(height + rowHeight, 1))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

