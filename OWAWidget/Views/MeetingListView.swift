import SwiftUI
import AppKit

struct MeetingDaySection: Identifiable, Equatable {
    var id: String { label }
    let label: String
    let date: Date
    let timedEvents: [CalendarEvent]
    let allDayEvents: [CalendarEvent]

    static func partition(
        events: [CalendarEvent],
        label: String,
        dayStart: Date,
        dayEnd: Date
    ) -> MeetingDaySection {
        let inDay = events.filter { $0.startDate < dayEnd && $0.endDate > dayStart }
        let allDay = inDay
            .filter { $0.isAllDay }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        let timed = inDay.filter { !$0.isAllDay }
        return MeetingDaySection(
            label: label,
            date: dayStart,
            timedEvents: timed,
            allDayEvents: allDay
        )
    }
}

struct MeetingListView: View {
    let sections: [MeetingDaySection]
    var contentHorizontalPadding: CGFloat = 12
    var selectedEventID: String? = nil
    var onSelect: (CalendarEvent) -> Void = { _ in }
    /// The day's name above its hours; off where a date bar right above already says it.
    var showsDayLabel = true
    /// Said over the grid when the day has no timed meetings; `nil` leaves the grid bare.
    var emptyMessage: String? = nil
    /// The calendar has not arrived yet: the empty message gets a spinner.
    var isLoading = false
    @EnvironmentObject private var localization: LocalizationService
    /// Bumped by every autoscroll request, so a stale retry from an earlier one stands down.
    @State private var autoScrollGeneration = 0

    private let timeColumnWidth: CGFloat = 56
    private let timelinePointsPerMinute: CGFloat = 1.0
    private let cardGap: CGFloat = 0
    private let slotDurationMinutes = 30

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(sections) { section in
                        Section {
                            hourlySection(section: section)
                        } header: {
                            VStack(alignment: .leading, spacing: 0) {
                                if showsDayLabel {
                                    sectionHeader(section.label)
                                }
                                AllDayEventsHeaderView(
                                    events: section.allDayEvents,
                                    contentHorizontalPadding: contentHorizontalPadding,
                                    timeColumnWidth: timeColumnWidth,
                                    selectedEventID: selectedEventID,
                                    onSelect: onSelect
                                )
                            }
                            .background(Color(nsColor: .windowBackgroundColor).opacity(0.95))
                        }
                    }
                }
            }
            .accessibilityElement(children: .contain)
            // A bare 24-hour grid read as "still loading" or "something broke"; a quiet note over
            // it says the day is simply free. Over the grid, not in it, so it stays in view
            // wherever the grid is scrolled, and clicks pass through.
            .overlay {
                if let emptyMessage, isEmptyDay {
                    HStack(spacing: 6) {
                        if isLoading {
                            ProgressView().controlSize(.small)
                        }
                        Text(emptyMessage)
                    }
                    .font(.app(.footnote, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .allowsHitTesting(false)
                    .accessibilityElement(children: .combine)
                    .transition(.opacity)
                }
            }
            .onAppear {
                scrollToCurrentSlot(proxy: proxy, reason: "appear")
            }
            // The popover's view tree outlives a close, and `onAppear` does not reliably fire on
            // reopen: without this the timeline shows wherever it was left hours ago.
            .onReceive(NotificationCenter.default.publisher(for: .owaPopoverDidOpen)) { _ in
                scrollToCurrentSlot(proxy: proxy, reason: "popover-open")
            }
            .onChange(of: sections.first?.date) { _ in
                scrollToCurrentSlot(proxy: proxy, reason: "day-change")
            }
        }
    }

    /// No meeting with a time. An all-day item (a birthday, a vacation) is not a meeting: it
    /// shows in its own row above the grid, and the day is still free.
    private var isEmptyDay: Bool {
        sections.allSatisfy { $0.timedEvents.isEmpty }
    }

    private func sectionHeader(_ label: String) -> some View {
        Text(label)
            .font(.app(.footnote, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, contentHorizontalPadding)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.95))
    }

    // MARK: - Section layout

    @ViewBuilder
    private func hourlySection(
        section: MeetingDaySection
    ) -> some View {
        let slots = TimelineMeetingLayout.makeHourSlots(
            events: section.timedEvents,
            sectionDate: section.date,
            calendar: AppTimeZone.calendar,
            referenceDate: Date()
        )

        if let firstSlot = slots.first {
            let allItems: [HourSlotMeetingItem] = {
                var seenIDs = Set<String>()
                return slots.flatMap(\.items).filter { seenIDs.insert($0.id).inserted }
            }()
            let gridStart = firstSlot.startDate
            let fixedSlotHeight = CGFloat(slotDurationMinutes) * timelinePointsPerMinute
            let gridPixelHeight = CGFloat(slots.count) * fixedSlotHeight

            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    ForEach(slots) { slot in
                        timeGridRow(slot, fixedHeight: fixedSlotHeight)
                            .id(slotID(for: section.date, slotStart: slot.startDate))
                    }
                }

                GeometryReader { geo in
                    ZStack(alignment: .topLeading) {
                        if !allItems.isEmpty {
                            let leftInset = timeColumnWidth + 10
                            let cardAreaWidth = max(0, geo.size.width - leftInset)
                            let laneSpacing: CGFloat = 0

                            ForEach(allItems) { item in
                                let laneCount = max(1, item.laneCount)
                                let cardFrame = TimelineMeetingLayout.cardFrame(
                                    for: item.event,
                                    laneIndex: item.laneIndex,
                                    laneCount: laneCount,
                                    gridStart: gridStart,
                                    leftInset: Double(leftInset),
                                    cardAreaWidth: Double(cardAreaWidth),
                                    laneSpacing: Double(laneSpacing),
                                    pointsPerMinute: Double(timelinePointsPerMinute),
                                    verticalGap: Double(cardGap)
                                )

                                Button { onSelect(item.event) } label: {
                                    TimelineMeetingBlockView(
                                        event: item.event,
                                        compact: laneCount > 1,
                                        showsOrganizer: TimelineMeetingLayout.showsTimelineOrganizer(
                                            laneIndex: item.laneIndex,
                                            laneCount: laneCount,
                                            eventDuration: item.event.duration
                                        ),
                                        isSelected: selectedEventID == item.event.id
                                    )
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(a11yEventLabel(item.event))
                                .accessibilityHint(localization.tr("a11y.meeting.open.details.hint"))
                                .frame(
                                    width: CGFloat(cardFrame.width),
                                    height: CGFloat(cardFrame.height),
                                    alignment: .topLeading
                                )
                                .position(
                                    x: CGFloat(cardFrame.centerX),
                                    y: CGFloat(cardFrame.centerY)
                                )
                            }
                        }
                    }
                    .frame(width: geo.size.width, height: max(geo.size.height, gridPixelHeight), alignment: .topLeading)
                }
            }
            .padding(.horizontal, contentHorizontalPadding)
            .padding(.bottom, 12)
        }
    }

    // MARK: - Time grid row (no cards)

    private func timeGridRow(_ slot: DayHourSlot, fixedHeight: CGFloat) -> some View {
        let isCurrentSlot = isCurrentTimeSlot(slot)
        let isHalfHourSlot = AppTimeZone.calendar.component(.minute, from: slot.startDate) == 30

        return HStack(alignment: .top, spacing: 10) {
            Text(!isHalfHourSlot ? localization.shortTime(slot.startDate) : "")
                .font(.app(.caption, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: timeColumnWidth, alignment: .trailing)

            Color.clear
        }
        .frame(height: fixedHeight, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isCurrentSlot ? Color.accentColor.opacity(0.08) : .clear)
        )
        .overlay(alignment: .top) {
            if !isHalfHourSlot {
                Rectangle()
                    .fill(Color(nsColor: .separatorColor).opacity(0.4))
                    .frame(height: 1)
                    .padding(.leading, timeColumnWidth + 10)
            }
        }
        // The grid is a visual scaffold; VoiceOver should focus on actual meeting cards.
        .accessibilityHidden(true)
    }

    private func a11yEventLabel(_ event: CalendarEvent) -> String {
        let time = "\(localization.shortTime(event.startDate))–\(localization.shortTime(event.endDate))"
        var parts: [String] = [event.title, time]
        if event.isHappeningNow {
            parts.append(localization.tr("meeting.happening.now"))
        }
        if let organizer = event.organizer, !organizer.isEmpty {
            parts.append(organizer)
        }
        if event.joinURLForActions != nil {
            parts.append(localization.tr("a11y.meeting.has.join"))
        }
        if event.isEffectivelyCancelled {
            parts.append(localization.tr("meeting.status.cancelled"))
        }
        return parts.joined(separator: ", ")
    }

    // MARK: - Scroll helpers

    private func isCurrentTimeSlot(_ slot: DayHourSlot) -> Bool {
        let now = Date()
        return slot.startDate <= now && now < slot.endDate
    }

    private func slotID(for sectionDate: Date, slotStart: Date) -> String {
        let sectionKey = Int(sectionDate.timeIntervalSince1970)
        let slotKey = Int(slotStart.timeIntervalSince1970)
        return "slot-\(sectionKey)-\(slotKey)"
    }

    /// Delays at which the scroll is applied. `scrollTo` reports nothing and quietly does nothing
    /// when the target has not been laid out yet — on the popover's first sizing, or while a day
    /// slides in (0.22 s) — and the list then stays at midnight. The late repeat lands after both.
    private static let autoScrollDelays: [UInt64] = [0, 300_000_000]

    private func scrollToCurrentSlot(proxy: ScrollViewProxy, reason: String) {
        guard let section = sections.first else { return }
        let calendar = AppTimeZone.calendar
        let now = Date()
        guard let slotStart = TimelineMeetingLayout.scrollAnchorSlotStart(
            sectionDate: section.date,
            now: now,
            calendar: calendar
        ) else {
            return
        }
        let id = slotID(for: section.date, slotStart: slotStart)
        DiagnosticLog.event(Self.autoScrollDiagnostic(reason: reason, now: now, slotStart: slotStart, calendar: calendar))

        autoScrollGeneration += 1
        let generation = autoScrollGeneration
        for delay in Self.autoScrollDelays {
            Task { @MainActor in
                if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
                guard generation == autoScrollGeneration else { return }
                // Deliberately not animated. This runs as the list appears, so there is no
                // previous position for the user to have seen it travel from — and when the list
                // appears as a page sliding in from the side, an animated scroll runs against
                // that slide over the same fifth of a second.
                proxy.scrollTo(id, anchor: .top)
            }
        }
    }

    /// Non-PII trace for "Copy diagnostics": both zones plus the clock and the anchor as the
    /// timeline sees them, enough to tell a wrong zone from a scroll that did not land.
    private static func autoScrollDiagnostic(reason: String, now: Date, slotStart: Date, calendar: Calendar) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = calendar.timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return "Timeline autoscroll reason=\(reason) display=\(calendar.timeZone.identifier) "
            + "system=\(TimeZone.current.identifier) now=\(f.string(from: now)) anchor=\(f.string(from: slotStart))"
    }
}
