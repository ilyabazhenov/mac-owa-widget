import SwiftUI
import AppKit

private struct SearchFieldHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 36
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

enum SlotViewMode: String, CaseIterable {
    case grid, list

    var iconName: String {
        switch self {
        case .grid: return "square.grid.3x2"
        case .list: return "list.bullet"
        }
    }

    var localizationKey: String {
        switch self {
        case .grid: return "create.meeting.view.grid"
        case .list: return "create.meeting.view.list"
        }
    }
}

struct CreateMeetingView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var localization: LocalizationService
    @StateObject private var vm: CreateMeetingViewModel
    @State private var requiredFieldHeight: CGFloat = 36
    @State private var optionalFieldHeight: CGFloat = 36
    @State private var slotViewMode: SlotViewMode = .grid
    @AppStorage("createMeeting.leftColumnWidth") private var leftColumnWidthRaw: Double = 320
    private var leftColumnWidth: CGFloat { CGFloat(leftColumnWidthRaw) }
    private var leftColumnWidthBinding: Binding<CGFloat> {
        Binding(get: { CGFloat(leftColumnWidthRaw) }, set: { leftColumnWidthRaw = Double($0) })
    }

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
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        titleField
                        timePickersField
                        attendeesField
                        if !vm.suggestedAttendees.isEmpty {
                            frequentContactsGrid
                        }
                        locationField
                        agendaField
                    }
                    .padding(20)
                }
                .frame(width: leftColumnWidth)

                ColumnResizeDivider(columnWidth: leftColumnWidthBinding)

                // Right column: slot selection
                VStack(spacing: 0) {
                    weekNavigator
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)
                    Divider()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            slotsContent
                        }
                        .padding(20)
                    }
                }
                .frame(minWidth: 380)
                .layoutPriority(1)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            }
            bottomBar
        }
        .frame(minWidth: 700, minHeight: 500)
        .background(WindowAccessor())
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay {
            if vm.successMessage != nil {
                MeetingCreatedOverlay(title: vm.draft.title, onDismiss: { dismiss() })
            }
        }
        .onDisappear {
            vm.reset()
        }
    }

    // MARK: - Title & agenda

    private var titleField: some View {
        formRow(localization.tr("create.meeting.title.label"), alignment: .top) {
            TextField(localization.tr("create.meeting.title.placeholder"), text: $vm.draft.title, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .lineLimit(1...3)
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
                .frame(minHeight: 36, alignment: .topLeading)
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
        formRow(localization.tr("create.meeting.agenda.label"), alignment: .top) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor))
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

    // MARK: - Location

    @State private var locationFieldHeight: CGFloat = 36
    @FocusState private var locationFieldFocused: Bool

    private var locationField: some View {
        formRow(localization.tr("create.meeting.location.label")) {
            HStack(spacing: 8) {
                Image(systemName: "link")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                TextField(localization.tr("create.meeting.location.placeholder"), text: $vm.draft.location)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($locationFieldFocused)
                    .onSubmit {
                        vm.recordLocationIfNeeded()
                        locationFieldFocused = false
                    }
                    .onChange(of: locationFieldFocused) { focused in
                        vm.locationFocused = focused
                        if !focused { vm.recordLocationIfNeeded() }
                    }
                if !vm.draft.location.isEmpty {
                    Button {
                        vm.draft.location = ""
                        locationFieldFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: SearchFieldHeightKey.self, value: geo.size.height)
                }
            )
            .onPreferenceChange(SearchFieldHeightKey.self) { locationFieldHeight = $0 }
            .overlay(alignment: .topLeading) {
                if vm.showLocationDropdown {
                    LocationDropdown(vm: vm, onSelect: {
                        vm.recordLocationIfNeeded()
                        locationFieldFocused = false
                    })
                    .offset(y: locationFieldHeight + 4)
                    .zIndex(10)
                    .background(
                        MouseDownDismissMonitor {
                            if vm.locationFocused { locationFieldFocused = false }
                        }
                        .frame(width: 0, height: 0)
                    )
                }
            }
        }
        .zIndex(vm.locationFocused ? 2 : 0)
    }

    // MARK: - Attendees

    private var attendeesField: some View {
        VStack(alignment: .leading, spacing: 10) {
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
        VStack(alignment: .leading, spacing: 4) {
            formRow(title, alignment: .top) {
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
            }
            if !list.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    Color.clear.frame(width: Self.labelColumnWidth)
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
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.top, 2)
            }
        }
        .overlay(alignment: .topLeading) {
            if vm.showDropdown(for: kind) {
                HStack(alignment: .top, spacing: 10) {
                    Color.clear.frame(width: Self.labelColumnWidth)
                    AttendeeDropdown(vm: vm, kind: kind)
                    Spacer(minLength: 0)
                }
                .offset(y: (kind == .required ? requiredFieldHeight : optionalFieldHeight) + 4)
                .allowsHitTesting(true)
            }
        }
    }

    // MARK: - Time pickers

    private var timePickersField: some View {
        VStack(spacing: 8) {
            formRow(localization.tr("create.meeting.time.start")) {
                timePickerControls(dateBinding: vm.slotStartBinding, range: nil)
            }
            formRow(localization.tr("create.meeting.time.end")) {
                timePickerControls(dateBinding: vm.slotEndBinding, range: vm.slotStartBinding.wrappedValue...)
            }
        }
    }

    private func timePickerControls(dateBinding: Binding<Date>, range: PartialRangeFrom<Date>?) -> some View {
        HStack(spacing: 6) {
            if let range {
                DatePicker("", selection: dateBinding, in: range, displayedComponents: .date)
                    .labelsHidden()
                    .datePickerStyle(.compact)
                    .frame(minWidth: 116)
                DatePicker("", selection: dateBinding, in: range, displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .datePickerStyle(.compact)
                    .frame(minWidth: 70)
            } else {
                DatePicker("", selection: dateBinding, displayedComponents: .date)
                    .labelsHidden()
                    .datePickerStyle(.compact)
                    .frame(minWidth: 116)
                DatePicker("", selection: dateBinding, displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .datePickerStyle(.compact)
                    .frame(minWidth: 70)
            }
        }
        .environment(\.calendar, AppTimeZone.calendar)
        .environment(\.timeZone, AppTimeZone.zone)
    }

    // MARK: - Frequent contacts grid

    private var frequentContactsGrid: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Color.clear.frame(width: Self.labelColumnWidth)
                sectionLabel(localization.tr("create.meeting.recent.label"))
            }
            HStack(spacing: 10) {
                Color.clear.frame(width: Self.labelColumnWidth)
                LazyVGrid(
                    columns: [GridItem(.flexible()), GridItem(.flexible())],
                    spacing: 4
                ) {
                    ForEach(vm.suggestedAttendees.prefix(12)) { record in
                        let isAdded = vm.draft.allAttendees.contains(record.attendee)
                        FrequentContactCard(attendee: record.attendee, count: record.useCount, isAdded: isAdded) {
                            if isAdded {
                                vm.removeAttendee(record.attendee)
                            } else {
                                vm.addAttendee(record.attendee)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Slots (right column)

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
                selectedSlot: vm.selectedSlot,
                onSelect: { vm.selectSlot(start: $0.start, end: $0.end) }
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
            VStack(spacing: 0) {
                WeekGridSlotView(
                    cellMatrix: vm.cellMatrix,
                    selectedSlot: vm.selectedSlot,
                    onSelectSlot: { vm.selectSlot(start: $0, end: $1) },
                    gridWeekInterval: vm.draft.slotGridWeekInterval()
                )
                .frame(height: MeetingSlotGridMetrics.gridHeight)
                if vm.slotsSearched && !vm.attendeeAvailabilities.isEmpty {
                    AvailabilityLegendView()
                        .padding(.horizontal, MeetingSlotGridMetrics.timeColumnWidth + 2)
                }
            }
            .frame(height: MeetingSlotsLayout.slotViewHeight, alignment: .top)
        case .list:
            ScrollView {
                SlotListView(
                    slots: vm.freeSlots,
                    selectedSlot: vm.selectedSlot,
                    onSelect: { vm.selectSlot(start: $0.start, end: $0.end) }
                )
                .padding(.bottom, 8)
            }
            .frame(height: MeetingSlotsLayout.slotViewHeight)
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

    private static let labelColumnWidth: CGFloat = 96

    private func formRow<Content: View>(
        _ label: String,
        alignment: VerticalAlignment = .firstTextBaseline,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: alignment, spacing: 10) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .frame(width: Self.labelColumnWidth, alignment: .trailing)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Meeting created overlay

private struct MeetingCreatedOverlay: View {
    let title: String
    let onDismiss: () -> Void
    @State private var countdown = 5
    @State private var timer: Timer?

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .opacity(0.85)

            VStack(spacing: 16) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.green)
                Text(title)
                    .font(.system(size: 18, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                Text("Закроется через \(countdown) сек")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Button("Закрыть") { onDismiss() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            .padding(40)
        }
        .ignoresSafeArea()
        .transition(.opacity.animation(.easeIn(duration: 0.15)))
        .onAppear {
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { t in
                if countdown > 1 {
                    countdown -= 1
                } else {
                    t.invalidate()
                    onDismiss()
                }
            }
        }
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
    }
}

// MARK: - Mouse-down dismiss helper

/// Installs an NSEvent local monitor while active.
/// On any left mouse down, fires `onDismiss` after one run-loop tick so that
/// SwiftUI button actions inside the dropdown can execute before the view disappears.
private struct MouseDownDismissMonitor: NSViewRepresentable {
    let onDismiss: () -> Void

    func makeNSView(context: Context) -> _MonitorView { _MonitorView() }

    func updateNSView(_ nsView: _MonitorView, context: Context) {
        nsView.onDismiss = onDismiss
    }

    class _MonitorView: NSView {
        var onDismiss: (() -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self?.onDismiss?() }
                    return event
                }
            } else {
                removeMonitor()
            }
        }

        private func removeMonitor() {
            if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        }

        deinit { removeMonitor() }
    }
}

// MARK: - Location dropdown

private struct LocationDropdown: View {
    @ObservedObject var vm: CreateMeetingViewModel
    let onSelect: () -> Void

    private static let rowHeight: CGFloat = 36
    private static let maxRows = 5

    private var suggestions: [LocationRecord] { vm.locationSuggestions }

    private var computedHeight: CGFloat {
        CGFloat(min(suggestions.count, Self.maxRows)) * Self.rowHeight
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(suggestions) { record in
                    LocationDropdownRow(url: record.url) {
                        vm.draft.location = record.url
                        onSelect()
                    }
                    if record.id != suggestions.last?.id {
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

private struct LocationDropdownRow: View {
    let url: String
    let onSelect: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Image(systemName: "link")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(url)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(nsColor: .labelColor))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(isHovered ? Color(nsColor: .selectedControlColor).opacity(0.5) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
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

// MARK: - Column resize divider

private struct ColumnResizeDivider: View {
    @Binding var columnWidth: CGFloat
    @State private var dragStartWidth: CGFloat? = nil
    private let minWidth: CGFloat = 240
    private let maxWidth: CGFloat = 520

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1)
            Color.clear
                .frame(width: 8)
                .contentShape(Rectangle())
                .onHover { hovered in
                    if hovered { NSCursor.resizeLeftRight.push() }
                    else { NSCursor.pop() }
                }
                .gesture(
                    DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { value in
                            if dragStartWidth == nil { dragStartWidth = columnWidth }
                            let proposed = (dragStartWidth ?? columnWidth) + value.translation.width
                            columnWidth = max(minWidth, min(maxWidth, proposed))
                        }
                        .onEnded { _ in dragStartWidth = nil }
                )
        }
    }
}

// MARK: - Frequent contact card

private struct FrequentContactCard: View {
    let attendee: ResolvedAttendee
    let count: Int
    let isAdded: Bool
    let onTap: () -> Void
    @State private var isHovered = false

    private var nameParts: [String] {
        attendee.displayName.components(separatedBy: " ").filter { !$0.isEmpty }
    }

    var body: some View {
        HStack(spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                InitialsAvatar(name: attendee.displayName, size: 26)
                if isAdded {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.white, Color.accentColor)
                        .offset(x: 3, y: 3)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(nameParts.first ?? attendee.displayName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isAdded ? Color.accentColor : Color(nsColor: .labelColor))
                    .lineLimit(1)
                if nameParts.count > 1 {
                    Text(nameParts.dropFirst().joined(separator: " "))
                        .font(.system(size: 10))
                        .foregroundStyle(isAdded ? Color.accentColor.opacity(0.8) : .secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if count > 1 {
                Text("×\(count)")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isAdded
                    ? Color.accentColor.opacity(0.08)
                    : (isHovered ? Color(nsColor: .controlColor) : Color.clear)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isAdded ? Color.accentColor.opacity(0.3) : Color.clear, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8))
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
    static let verticalSpacing: CGFloat = 2
    static let timeColumnWidth: CGFloat = 44
    static let headerHeight: CGFloat = 28
    /// Высота WeekGridSlotView: шапка + 18 строк + 18 промежутков verticalSpacing + padding(.vertical, 4) × 2.
    static var gridHeight: CGFloat { headerHeight + rowHeight * 18 + 18 * verticalSpacing + 8 }
    /// Полная высота блока: грид + легенда занятости (24pt).
    static var totalHeight: CGFloat { gridHeight + 24 }
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


private struct FirstDataRowOriginYKey: PreferenceKey {
    static let defaultValue: CGFloat = -1
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let n = nextValue()
        if n >= 0 { value = n }
    }
}

struct WeekGridSlotView: View {
    private typealias TimeKey = Int
    private typealias DayKey = Date

    private struct HoveredInfo {
        let cell: CellAvailability
        let cellStart: Date
    }

    private struct DragPreview {
        let day: Date
        let startMinute: Int
        let endMinute: Int
    }

    let cellMatrix: [Date: [Int: CellAvailability]]
    let selectedSlot: FreeSlot?
    let onSelectSlot: (Date, Date) -> Void
    let gridWeekInterval: DateInterval

    @State private var hoveredInfo: HoveredInfo? = nil
    @State private var mousePosition: CGPoint = .zero
    @State private var dragPreview: DragPreview? = nil
    @State private var firstDataRowOriginY: CGFloat = 32

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

    private static let selFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.timeZone = AppTimeZone.zone
        return f
    }()

    private var days: [DayKey] {
        gridWeekInterval.weekdayColumnStartDates(calendar: AppTimeZone.calendar)
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

    /// Позиция тултипа: рядом с курсором, не выходя за границы (approx 240×100pt tooltip).
    private func tooltipOffset(in viewSize: CGSize) -> CGSize {
        let tooltipW: CGFloat = 244
        let tooltipH: CGFloat = 110
        let gap: CGFloat = 12
        let x = mousePosition.x + gap + tooltipW > viewSize.width
            ? mousePosition.x - tooltipW - gap
            : mousePosition.x + gap
        let y = mousePosition.y + tooltipH > viewSize.height
            ? mousePosition.y - tooltipH
            : mousePosition.y
        return CGSize(width: x, height: y)
    }

    var body: some View {
        let columnDays = days
        let topEdge = Color(nsColor: .separatorColor).opacity(0.62)
        GeometryReader { geo in
            Grid(horizontalSpacing: 0, verticalSpacing: MeetingSlotGridMetrics.verticalSpacing) {
                GridRow {
                    Color.clear
                        .frame(minWidth: MeetingSlotGridMetrics.timeColumnWidth, maxWidth: MeetingSlotGridMetrics.timeColumnWidth, minHeight: 28)
                        .meetingSlotGridLines(leading: true, trailing: true, bottom: true, bottomIsMajor: true)
                    ForEach(columnDays, id: \.self) { day in
                        columnHeader(for: day)
                            .padding(.vertical, 4)
                            .meetingSlotGridLines(trailing: true, bottom: true, bottomIsMajor: true)
                    }
                }
                ForEach(Array(Self.timeRows.enumerated()), id: \.offset) { _, timeKey in
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
                            .background {
                                if timeKey == 540 {
                                    GeometryReader { cellGeo in
                                        Color.clear.preference(
                                            key: FirstDataRowOriginYKey.self,
                                            value: cellGeo.frame(in: .named("weekGrid")).minY
                                        )
                                    }
                                }
                            }
                        ForEach(columnDays, id: \.self) { day in
                            let cell = cellMatrix[day]?[timeKey]
                            let cellStart = AppTimeZone.calendar.date(
                                bySettingHour: timeKey / 60, minute: timeKey % 60, second: 0, of: day
                            ) ?? day
                            // Determine selection range: confirmed slot or active drag preview.
                            let activeSlot: FreeSlot? = {
                                if let p = dragPreview, AppTimeZone.calendar.isDate(day, inSameDayAs: p.day) {
                                    let cal = AppTimeZone.calendar
                                    guard let s = cal.date(bySettingHour: p.startMinute / 60, minute: p.startMinute % 60, second: 0, of: p.day),
                                          let e = cal.date(bySettingHour: p.endMinute   / 60, minute: p.endMinute   % 60, second: 0, of: p.day)
                                    else { return nil }
                                    return FreeSlot(start: s, end: e)
                                }
                                if let slot = selectedSlot, AppTimeZone.calendar.isDate(cellStart, inSameDayAs: slot.start) {
                                    return slot
                                }
                                return nil
                            }()
                            let isSelected = activeSlot.map { cellStart >= $0.start && cellStart < $0.end } == true
                            let slotPos: FreeSlotPosition? = isSelected ? {
                                guard let r = activeSlot else { return .single }
                                let n = max(1, Int((r.end.timeIntervalSince(r.start) / 1800).rounded()))
                                if n == 1 { return .single }
                                let i = max(0, Int((cellStart.timeIntervalSince(r.start) / 1800).rounded()))
                                if i == 0 { return .start }
                                if i == n - 1 { return .end }
                                return .middle
                            }() : nil
                            let effectivePos = slotPos ?? cell?.slotPosition ?? .single
                            let showBottom = effectivePos != .start && effectivePos != .middle
                            let isPast = cellStart.addingTimeInterval(30 * 60) <= Date()
                            AvailabilityCell(
                                cell: cell,
                                isSelected: isSelected,
                                isPast: isPast,
                                onHoverChange: { hovered in
                                    guard dragPreview == nil else { return }
                                    let tooltipStart = cell?.freeSlot?.start ?? cellStart
                                    hoveredInfo = hovered ? HoveredInfo(cell: cell!, cellStart: tooltipStart) : nil
                                },
                                slotPositionOverride: slotPos,
                                displaySlot: isSelected ? activeSlot : cell?.freeSlot
                            )
                            .frame(maxWidth: .infinity, minHeight: MeetingSlotGridMetrics.rowHeight, maxHeight: MeetingSlotGridMetrics.rowHeight)
                            .meetingSlotGridLines(trailing: true, bottom: showBottom, bottomIsMajor: rowEndsOnHour && showBottom)
                        }
                    }
                }
            }
            .coordinateSpace(name: "weekGrid")
            .onPreferenceChange(FirstDataRowOriginYKey.self) { firstDataRowOriginY = $0 }
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): mousePosition = point
                case .ended: hoveredInfo = nil
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        hoveredInfo = nil
                        let colCount = CGFloat(columnDays.count)
                        let colW = (geo.size.width - MeetingSlotGridMetrics.timeColumnWidth) / colCount
                        let colIdx = max(0, min(Int(colCount) - 1,
                            Int((value.startLocation.x - MeetingSlotGridMetrics.timeColumnWidth) / colW)))
                        let rowOf: (CGPoint) -> Int = { pt in
                            max(0, min(17, Int((pt.y - MeetingSlotGridMetrics.headerHeight - 4) / (MeetingSlotGridMetrics.rowHeight + MeetingSlotGridMetrics.verticalSpacing))))
                        }
                        let startRow = rowOf(value.startLocation)
                        let endRow   = rowOf(value.location)
                        let minRow = min(startRow, endRow)
                        let maxRow = max(startRow, endRow)
                        dragPreview = DragPreview(
                            day: columnDays[colIdx],
                            startMinute: 9 * 60 + minRow * 30,
                            endMinute:   9 * 60 + (maxRow + 1) * 30
                        )
                    }
                    .onEnded { _ in
                        if let p = dragPreview {
                            let cal = AppTimeZone.calendar
                            if let s = cal.date(bySettingHour: p.startMinute / 60, minute: p.startMinute % 60, second: 0, of: p.day),
                               let e = cal.date(bySettingHour: p.endMinute   / 60, minute: p.endMinute   % 60, second: 0, of: p.day) {
                                onSelectSlot(s, e)
                            }
                        }
                        dragPreview = nil
                    }
            )
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(topEdge)
                    .frame(height: 1)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .topLeading) {
                let colCount = CGFloat(columnDays.count)
                let colW = (geo.size.width - MeetingSlotGridMetrics.timeColumnWidth) / colCount
                let overlayData: (colIdx: Int, startMin: Int, endMin: Int, confirmedSlot: FreeSlot?)? = {
                    if let p = dragPreview,
                       let idx = columnDays.firstIndex(where: { AppTimeZone.calendar.isDate($0, inSameDayAs: p.day) }) {
                        return (idx, p.startMinute, p.endMinute, nil)
                    }
                    if let slot = selectedSlot,
                       let idx = columnDays.firstIndex(where: { AppTimeZone.calendar.isDate($0, inSameDayAs: slot.start) }) {
                        let cal = AppTimeZone.calendar
                        let sc = cal.dateComponents([.hour, .minute], from: slot.start)
                        let ec = cal.dateComponents([.hour, .minute], from: slot.end)
                        let sm = (sc.hour ?? 0) * 60 + (sc.minute ?? 0)
                        let em = (ec.hour ?? 0) * 60 + (ec.minute ?? 0)
                        return (idx, sm, em, slot)
                    }
                    return nil
                }()
                if let od = overlayData {
                    let startRow = (od.startMin - 540) / 30
                    let nRows    = max(1, (od.endMin - od.startMin) / 30)
                    let rH = MeetingSlotGridMetrics.rowHeight
                    let vS = MeetingSlotGridMetrics.verticalSpacing
                    let topY   = firstDataRowOriginY
                               + CGFloat(startRow) * (rH + vS)
                    let height = CGFloat(nRows) * rH + CGFloat(nRows - 1) * vS
                    let x      = MeetingSlotGridMetrics.timeColumnWidth + CGFloat(od.colIdx) * colW + 2
                    let width  = colW - 4
                    ZStack {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color.accentColor)
                        if let slot = od.confirmedSlot {
                            Text("Выбрано: \(WeekGridSlotView.selFmt.string(from: slot.start)) – \(WeekGridSlotView.selFmt.string(from: slot.end))")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.white)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 4)
                        }
                    }
                    .frame(width: width, height: height)
                    .offset(x: x, y: topY)
                    .allowsHitTesting(false)
                    .animation(.easeInOut(duration: 0.12), value: od.startMin)
                    .animation(.easeInOut(duration: 0.12), value: od.endMin)
                }
            }
            .overlay(alignment: .topLeading) {
                if let info = hoveredInfo {
                    let offset = tooltipOffset(in: geo.size)
                    CellTooltipView(cell: info.cell, cellStart: info.cellStart)
                        .offset(x: offset.width, y: offset.height)
                        .allowsHitTesting(false)
                        .zIndex(500)
                }
            }
        }
        .frame(height: MeetingSlotGridMetrics.headerHeight + MeetingSlotGridMetrics.rowHeight * 18 + 18 * MeetingSlotGridMetrics.verticalSpacing)
        .padding(.vertical, 4)
    }
}

private struct AvailabilityCell: View {
    let cell: CellAvailability?
    let isSelected: Bool
    let isPast: Bool
    let onHoverChange: (Bool) -> Void
    let slotPositionOverride: FreeSlotPosition?
    let displaySlot: FreeSlot?

    @State private var isHovered = false
    @Environment(\.colorScheme) private var colorScheme

    private var isSelectable: Bool { cell != nil && !isPast }

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.timeZone = AppTimeZone.zone
        return f
    }()

    private static func abbreviate(_ name: String) -> String {
        let parts = name.split(separator: " ")
        guard parts.count >= 2 else { return String(name.prefix(12)) }
        return "\(parts[0]) \(parts[1].prefix(1))."
    }

    private var cellLabel: String? {
        guard let cell else { return nil }
        guard !isSelected else { return nil }
        switch cell.state {
        case .free:
            return "Свободно"
        case .tentative, .busy, .outOfOffice:
            let blocked = cell.attendeeStatuses.filter { $0.rawChar != "0" }
            guard !blocked.isEmpty else { return nil }
            let first = Self.abbreviate(blocked[0].displayName)
            return blocked.count == 1 ? first : "\(first) +\(blocked.count - 1)"
        }
    }

    private var labelColor: Color {
        guard let cell else { return .primary }
        if case .free = cell.state {
            if isPast {
                return colorScheme == .dark
                    ? Color(hue: 0.385, saturation: 0.55, brightness: 0.30)
                    : Color(hue: 0.385, saturation: 0.60, brightness: 0.38)
            }
            return colorScheme == .dark
                ? .white.opacity(0.88)
                : Color(hue: 0.385, saturation: 0.70, brightness: 0.35).opacity(0.85)
        }
        return .primary.opacity(0.65)
    }

    private var bg: Color {
        guard let cell else { return .clear }
        // selected cells show through from overlay; no separate fill here
        if colorScheme == .dark {
            // Насыщенные jewel-тона под тёмный фон
            switch cell.state {
            case .free:
                return Color(hue: 0.420, saturation: 0.60, brightness: 0.78)
                    .opacity(isHovered ? 1.00 : 0.90)
            case .tentative:
                return Color(hue: 0.117, saturation: 0.75, brightness: 0.88)
                    .opacity(isHovered ? 0.95 : 0.85)
            case .busy:
                return Color(hue: 0.970, saturation: 0.72, brightness: 0.65)
                    .opacity(isHovered ? 0.95 : 0.88)
            case .outOfOffice:
                return Color(hue: 0.700, saturation: 0.65, brightness: 0.76)
                    .opacity(isHovered ? 0.92 : 0.80)
            }
        } else {
            // Настоящие пастели под светлый фон
            switch cell.state {
            case .free:
                return Color(hue: 0.385, saturation: 0.32, brightness: 0.88)
                    .opacity(isHovered ? 1.00 : 0.90)
            case .tentative:
                return Color(hue: 0.075, saturation: 0.40, brightness: 0.97)
                    .opacity(isHovered ? 1.00 : 0.90)
            case .busy:
                return Color(hue: 0.975, saturation: 0.35, brightness: 0.90)
                    .opacity(isHovered ? 1.00 : 0.90)
            case .outOfOffice:
                return Color(hue: 0.700, saturation: 0.28, brightness: 0.90)
                    .opacity(isHovered ? 1.00 : 0.90)
            }
        }
    }

    private var slotPosition: FreeSlotPosition { slotPositionOverride ?? cell?.slotPosition ?? .single }

    @ViewBuilder
    private var cellShape: some View {
        RoundedRectangle(cornerRadius: 5).fill(bg)
    }

    var body: some View {
        ZStack {
            cellShape
            if let label = cellLabel {
                HStack(spacing: 0) {
                    Text(label)
                        .font(.system(size: 8.5, weight: .medium))
                        .foregroundStyle(labelColor)
                        .lineLimit(1)
                        .padding(.leading, 5)
                    Spacer(minLength: 0)
                }
            }
            // "Выбрано" label is rendered by WeekGridSlotView overlay instead
        }
        .padding(.horizontal, 2)
        .frame(maxWidth: .infinity)
        .frame(height: MeetingSlotGridMetrics.rowHeight)
        .opacity(isPast ? 0.55 : 1.0)
        .scaleEffect(isSelectable && isHovered && !isSelected ? 1.04 : 1.0)
        .zIndex(isHovered ? 1 : 0)
        .contentShape(Rectangle())
        .onHover { hovered in
            let active = hovered && cell != nil
            isHovered = active
            onHoverChange(active)
        }
        .animation(.easeInOut(duration: 0.12), value: isSelected)
        .animation(.easeInOut(duration: 0.12), value: isHovered)
    }
}

private struct CellTooltipView: View {
    let cell: CellAvailability
    let cellStart: Date
    @EnvironmentObject private var localization: LocalizationService

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.timeZone = AppTimeZone.zone
        return f
    }()

    private static let dayTimeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE, HH:mm"
        f.timeZone = AppTimeZone.zone
        return f
    }()

    private func statusColor(for ch: Character) -> Color {
        switch ch {
        case "0": return Color(hue: 0.420, saturation: 0.72, brightness: 0.65)
        case "1": return Color(hue: 0.125, saturation: 0.72, brightness: 0.70)
        case "2": return Color(hue: 0.970, saturation: 0.68, brightness: 0.58)
        case "3": return Color(hue: 0.700, saturation: 0.60, brightness: 0.68)
        default:  return Color.secondary
        }
    }

    private func statusLabel(for ch: Character) -> String {
        switch ch {
        case "0": return "свободен"
        case "1": return "под вопросом"
        case "2": return "занят"
        case "3": return "вне офиса"
        default:  return "—"
        }
    }

    private var slotQualityNote: String? {
        guard case .free(let score) = cell.state, cell.freeSlot != nil else { return nil }
        return score >= 0.55 ? "Хороший слот — утро" : "Приемлемо — вечер"
    }

    @ViewBuilder
    private func attendeeRow(_ status: AttendeeSlotStatus) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 7) {
                Circle()
                    .fill(statusColor(for: status.rawChar))
                    .frame(width: 8, height: 8)
                Text(status.displayName)
                    .font(.system(size: 11))
                    .lineLimit(1)
                Spacer()
                Text(statusLabel(for: status.rawChar))
                    .font(.system(size: 10))
                    .foregroundStyle(statusColor(for: status.rawChar).opacity(0.85))
            }
            if let title = status.eventTitle {
                Text(title)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.leading, 15)
            }
        }
    }

    var body: some View {
        let cellEnd = cell.freeSlot?.end ?? cellStart.addingTimeInterval(30 * 60)
        VStack(alignment: .leading, spacing: 5) {
            Text("\(Self.dayTimeFmt.string(from: cellStart)) – \(Self.timeFmt.string(from: cellEnd))")
                .font(.system(size: 11, weight: .semibold))
            Divider()
            ForEach(cell.attendeeStatuses.indices, id: \.self) { idx in
                attendeeRow(cell.attendeeStatuses[idx])
            }
            if !cell.optionalAttendeeStatuses.isEmpty {
                Divider()
                Text(localization.tr("create.meeting.tooltip.optional"))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                ForEach(cell.optionalAttendeeStatuses.indices, id: \.self) { idx in
                    attendeeRow(cell.optionalAttendeeStatuses[idx])
                }
            }
            if let note = slotQualityNote {
                Divider()
                Text(note)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(minWidth: 180, maxWidth: 240)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 4)
    }
}

private struct AvailabilityLegendView: View {
    @EnvironmentObject private var localization: LocalizationService

    private struct Item {
        let color: Color
        let key: String
    }

    private static let items: [Item] = [
        Item(color: Color(hue: 0.385, saturation: 0.42, brightness: 0.78), key: "create.meeting.legend.free"),
        Item(color: Color(hue: 0.075, saturation: 0.48, brightness: 0.90), key: "create.meeting.legend.tentative"),
        Item(color: Color(hue: 0.975, saturation: 0.42, brightness: 0.80), key: "create.meeting.legend.busy"),
        Item(color: Color(hue: 0.700, saturation: 0.35, brightness: 0.80), key: "create.meeting.legend.oof"),
    ]

    var body: some View {
        HStack(spacing: 12) {
            ForEach(Self.items.indices, id: \.self) { idx in
                HStack(spacing: 5) {
                    Circle()
                        .fill(Self.items[idx].color)
                        .frame(width: 7, height: 7)
                    Text(localization.tr(Self.items[idx].key))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .frame(height: 20)
        .padding(.top, 4)
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

// MARK: - Window accessor

private struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            view.window?.setFrameAutosaveName("CreateMeetingWindow")
            view.window?.makeKeyAndOrderFront(nil)
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
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

