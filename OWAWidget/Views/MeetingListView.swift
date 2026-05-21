import SwiftUI
import AppKit

struct MeetingListView: View {
    let sections: [(label: String, date: Date, events: [CalendarEvent])]
    var contentHorizontalPadding: CGFloat = 12
    var selectedEventID: String? = nil
    var onSelect: (CalendarEvent) -> Void = { _ in }
    @EnvironmentObject private var localization: LocalizationService
    @State private var hasAutoScrolledToCurrentSlot = false

    private let timeColumnWidth: CGFloat = 56
    private let timelinePointsPerMinute: CGFloat = 1.0
    private let cardGap: CGFloat = 0
    private let slotDurationMinutes = 30

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(sections, id: \.label) { section in
                        Section {
                            hourlySection(section: section)
                        } header: {
                            sectionHeader(section.label)
                        }
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .onAppear {
                hasAutoScrolledToCurrentSlot = false
                scrollToCurrentSlotIfNeeded(proxy: proxy)
            }
            .onChange(of: sections.map(\.events.count)) { _ in
                scrollToCurrentSlotIfNeeded(proxy: proxy)
            }
            .onChange(of: sections.first?.date) { _ in
                hasAutoScrolledToCurrentSlot = false
                scrollToCurrentSlotIfNeeded(proxy: proxy)
            }
        }
    }

    private func sectionHeader(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, contentHorizontalPadding)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.95))
    }

    // MARK: - Section layout

    @ViewBuilder
    private func hourlySection(
        section: (label: String, date: Date, events: [CalendarEvent])
    ) -> some View {
        let slots = TimelineMeetingLayout.makeHourSlots(
            events: section.events,
            sectionDate: section.date,
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
                .font(.system(size: 10, weight: .medium))
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

    private func startOfSlot(containing date: Date, calendar: Calendar) -> Date? {
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        guard
            let hour = components.hour,
            let minute = components.minute
        else {
            return nil
        }

        let snappedMinute = (minute / slotDurationMinutes) * slotDurationMinutes
        return calendar.date(
            from: DateComponents(
                year: components.year,
                month: components.month,
                day: components.day,
                hour: hour,
                minute: snappedMinute,
                second: 0
            )
        )
    }

    private func scrollToCurrentSlotIfNeeded(proxy: ScrollViewProxy) {
        guard !hasAutoScrolledToCurrentSlot else { return }
        guard let id = scrollAnchorSlotID() else { return }

        hasAutoScrolledToCurrentSlot = true
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.2)) {
                proxy.scrollTo(id, anchor: .top)
            }
        }
    }

    // Returns the slot 2 hours before current time so that after scrolling
    // the current moment appears lower on the timeline with more context above.
    private func scrollAnchorSlotID() -> String? {
        let now = Date()
        let calendar = AppTimeZone.calendar
        guard let section = sections.first(where: { calendar.isDate($0.date, inSameDayAs: now) }) else {
            return nil
        }
        let anchorTime = now.addingTimeInterval(-2 * 60 * 60)
        guard let slotStart = startOfSlot(containing: anchorTime, calendar: calendar) else {
            return nil
        }
        return slotID(for: section.date, slotStart: slotStart)
    }
}
