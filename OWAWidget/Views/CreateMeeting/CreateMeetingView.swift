import SwiftUI
import AppKit

private struct SearchFieldHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 36
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct CreateMeetingView: View {
    @EnvironmentObject private var localization: LocalizationService
    @StateObject private var vm: CreateMeetingViewModel
    @State private var searchFieldHeight: CGFloat = 36

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
                        titleField
                        attendeesField
                        rangeAndDuration
                        findSlotsButton
                    }
                    .padding(20)

                    if !vm.suggestedAttendees.isEmpty {
                        Divider()
                        frequentContactsGrid
                    } else {
                        Spacer()
                    }
                }
                .frame(width: 300)

                Divider()

                // Right column: slot selection
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        slotsSection
                    }
                    .padding(20)
                }
                .frame(width: 340)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            }
            bottomBar
        }
        .frame(width: 660)
        .background(Color(nsColor: .windowBackgroundColor))
        .background(FloatingWindowSetter())
    }

    // MARK: - Title

    private var titleField: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel(localization.tr("create.meeting.title.placeholder"))
            TextField(localization.tr("create.meeting.title.placeholder"), text: $vm.draft.title)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
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
        }
    }

    // MARK: - Attendees

    private var attendeesField: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel(localization.tr("create.meeting.attendees.label"))
            AttendeeSearchField(vm: vm)
                .background(
                    // Measure the search field's height so the dropdown can offset by exactly that.
                    GeometryReader { geo in
                        Color.clear.preference(key: SearchFieldHeightKey.self, value: geo.size.height)
                    }
                )
                .onPreferenceChange(SearchFieldHeightKey.self) { searchFieldHeight = $0 }
                .overlay(alignment: .topLeading) {
                    if vm.showDropdown {
                        AttendeeDropdown(vm: vm)
                            .offset(y: searchFieldHeight + 4)
                    }
                }
                .zIndex(1)
            if !vm.draft.attendees.isEmpty {
                attendeeChips
            }
        }
        .zIndex(1)
    }

    private var attendeeChips: some View {
        FlowLayout(spacing: 6) {
            ForEach(vm.draft.attendees) { attendee in
                AttendeeChipView(attendee: attendee) {
                    vm.removeAttendee(attendee)
                }
            }
        }
        .padding(.top, 2)
    }

    // MARK: - Range & Duration

    private var rangeAndDuration: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                sectionLabel(localization.tr("create.meeting.range.label"))
                Picker("", selection: $vm.draft.searchRange) {
                    ForEach(MeetingSearchRange.allCases, id: \.self) { range in
                        Text(localization.tr(range.localizationKey)).tag(range)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity)
            }

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
                        let isAdded = vm.draft.attendees.contains(attendee)
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

    // MARK: - Find slots button

    private var findSlotsButton: some View {
        Button {
            Task { await vm.findSlots() }
        } label: {
            HStack(spacing: 6) {
                if vm.isLoadingSlots {
                    ProgressView().scaleEffect(0.7).frame(width: 14, height: 14)
                } else {
                    Image(systemName: "calendar.badge.clock")
                        .font(.system(size: 12))
                }
                Text(localization.tr("create.meeting.find.slots"))
                    .font(.system(size: 13, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        .buttonStyle(.borderedProminent)
        .disabled(vm.draft.attendees.isEmpty || vm.isLoadingSlots)
        .controlSize(.regular)
    }

    // MARK: - Slots (right column)

    @ViewBuilder
    private var slotsSection: some View {
        if vm.isLoadingSlots {
            VStack {
                Spacer()
                ProgressView()
                    .padding(.top, 60)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else if vm.slotsSearched && vm.freeSlots.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "calendar.badge.exclamationmark")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                Text(localization.tr("create.meeting.no.slots"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 50)
        } else if !vm.freeSlots.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    sectionLabel(localization.tr("create.meeting.available.slots"))
                    Spacer()
                    TimeZoneBadge()
                }
                SlotsByDayView(slots: vm.freeSlots, selectedSlotID: $vm.selectedSlotID)
            }
        } else {
            // Idle — prompt user to add attendees and search
            VStack(spacing: 10) {
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 28))
                    .foregroundStyle(.quaternary)
                Text(localization.tr("create.meeting.slots.hint"))
                    .font(.system(size: 12))
                    .foregroundStyle(.quaternary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 50)
        }
    }

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

    private static let rowHeight: CGFloat = 50
    private static let maxRows = 5

    /// As an overlay child, SwiftUI proposes the parent (search field) height to us — too small for content.
    /// Compute an explicit height instead so the dropdown sizes to its rows (and scrolls only when needed).
    private var computedHeight: CGFloat {
        let visibleRows = min(vm.searchResults.count, Self.maxRows)
        return CGFloat(visibleRows) * Self.rowHeight
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(vm.searchResults) { attendee in
                    DropdownRowView(attendee: attendee) {
                        vm.addAttendee(attendee)
                    }
                    if attendee.id != vm.searchResults.last?.id {
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
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            InitialsAvatar(name: attendee.displayName, size: 18)
            Text(attendee.displayName.components(separatedBy: " ").prefix(2).joined(separator: " "))
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
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
                .fill(Color(nsColor: .controlColor))
        )
        .overlay(
            Capsule()
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
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

// MARK: - Slots grouped by day

private struct SlotsByDayView: View {
    let slots: [FreeSlot]
    @Binding var selectedSlotID: UUID?

    private static let dayKeyFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = AppTimeZone.zone; return f
    }()
    private static let dayHeaderFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEEE, d MMMM"; f.timeZone = AppTimeZone.zone; return f
    }()
    private static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; f.timeZone = AppTimeZone.zone; return f
    }()

    private var grouped: [(day: String, header: String, slots: [FreeSlot])] {
        var order: [String] = []
        var map: [String: [FreeSlot]] = [:]
        for slot in slots {
            let key = Self.dayKeyFmt.string(from: slot.start)
            if map[key] == nil { order.append(key) }
            map[key, default: []].append(slot)
        }
        return order.map { key in
            let header = Self.dayHeaderFmt.string(from: map[key]!.first!.start).capitalized
            return (day: key, header: header, slots: map[key]!)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(grouped, id: \.day) { group in
                VStack(alignment: .leading, spacing: 0) {
                    // Day header
                    HStack(spacing: 6) {
                        Text(group.header)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                        Rectangle()
                            .fill(Color.accentColor.opacity(0.2))
                            .frame(height: 1)
                    }
                    .padding(.bottom, 6)

                    // Slots for this day
                    VStack(spacing: 6) {
                        ForEach(group.slots) { slot in
                            let isSelected = selectedSlotID == slot.id
                            Button {
                                selectedSlotID = slot.id
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 15))
                                        .foregroundStyle(isSelected ? Color.accentColor : Color(nsColor: .tertiaryLabelColor))
                                        .frame(width: 20)

                                    Text("\(Self.timeFmt.string(from: slot.start)) – \(Self.timeFmt.string(from: slot.end))")
                                        .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                                        .foregroundStyle(Color(nsColor: .labelColor))

                                    Spacer()

                                    if isSelected {
                                        Text("выбрано")
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundStyle(Color.accentColor)
                                            .padding(.horizontal, 7)
                                            .padding(.vertical, 3)
                                            .background(Color.accentColor.opacity(0.1))
                                            .clipShape(Capsule())
                                    }
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(isSelected ? Color.accentColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(isSelected ? Color.accentColor.opacity(0.4) : Color(nsColor: .separatorColor), lineWidth: isSelected ? 1 : 0.5)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
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

// MARK: - Floating window helper

private struct FloatingWindowSetter: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            view.window?.level = .floating
            view.window?.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
