import SwiftUI

struct MeetingListView: View {
    let sections: [(label: String, date: Date, events: [CalendarEvent])]
    @EnvironmentObject private var localization: LocalizationService
    @State private var hasAutoScrolledToCurrentSlot = false

    private let timeColumnWidth: CGFloat = 56
    private let timelinePointsPerMinute: CGFloat = 1.0
    private let cardGap: CGFloat = 6
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
            .onAppear {
                scrollToCurrentSlotIfNeeded(proxy: proxy)
            }
            .onChange(of: sections.map(\.events.count)) { _ in
                scrollToCurrentSlotIfNeeded(proxy: proxy)
            }
        }
    }

    private func sectionHeader(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.95))
    }

    // MARK: - Section layout

    private func hourlySection(
        section: (label: String, date: Date, events: [CalendarEvent])
    ) -> some View {
        let slots = TimelineMeetingLayout.makeHourSlots(
            events: section.events,
            sectionDate: section.date,
            referenceDate: Date()
        )

        guard let firstSlot = slots.first else { return AnyView(EmptyView()) }

        // Each event appears in only its first overlapping slot; deduplicate for the overlay.
        var seenIDs = Set<String>()
        let allItems = slots.flatMap { $0.items }.filter { seenIDs.insert($0.id).inserted }
        let gridStart = firstSlot.startDate
        let fixedSlotHeight = CGFloat(slotDurationMinutes) * timelinePointsPerMinute

        return AnyView(
            VStack(spacing: 0) {
                ForEach(slots) { slot in
                    timeGridRow(slot, fixedHeight: fixedSlotHeight)
                        .id(slotID(for: section.date, slotStart: slot.startDate))
                }
            }
            .overlay(alignment: .topLeading) {
                if !allItems.isEmpty {
                    GeometryReader { geo in
                        // Cards are placed starting after the time column.
                        let leftInset = timeColumnWidth + 10
                        let cardAreaWidth = max(0, geo.size.width - leftInset)
                        let laneSpacing: CGFloat = 6

                        ForEach(allItems) { item in
                            let laneCount = max(1, item.laneCount)
                            let cardWidth = max(
                                0,
                                (cardAreaWidth - CGFloat(laneCount - 1) * laneSpacing) / CGFloat(laneCount)
                            )
                            let xOffset = leftInset + CGFloat(item.laneIndex) * (cardWidth + laneSpacing)

                            let minutesFromStart = max(
                                0.0,
                                item.event.startDate.timeIntervalSince(gridStart) / 60
                            )
                            let yOffset = CGFloat(minutesFromStart) * timelinePointsPerMinute
                            let cardHeight = max(
                                30 - cardGap,
                                min(96, CGFloat(item.event.duration / 60) * timelinePointsPerMinute - cardGap)
                            )

                            TimelineMeetingBlockView(event: item.event, compact: laneCount > 1)
                                .frame(width: cardWidth, height: cardHeight)
                                .offset(x: xOffset, y: yOffset)
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        )
    }

    // MARK: - Time grid row (no cards)

    private func timeGridRow(_ slot: DayHourSlot, fixedHeight: CGFloat) -> some View {
        let isCurrentSlot = isCurrentTimeSlot(slot)
        let isHalfHourSlot = Calendar.current.component(.minute, from: slot.startDate) == 30

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

    private func currentSlotID() -> String? {
        let now = Date()
        let calendar = Calendar.current

        guard let section = sections.first(where: { calendar.isDate($0.date, inSameDayAs: now) }) else {
            return nil
        }
        guard let slotStart = startOfSlot(containing: now, calendar: calendar) else {
            return nil
        }
        return slotID(for: section.date, slotStart: slotStart)
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
        guard let id = currentSlotID() else { return }

        debugLogCurrentSlot(targetID: id)
        hasAutoScrolledToCurrentSlot = true
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.2)) {
                proxy.scrollTo(id, anchor: .center)
            }
        }
    }

    private func debugLogCurrentSlot(targetID: String) {
        #if DEBUG
        let now = Date()
        let calendar = Calendar.current
        let timeZone = TimeZone.current.identifier
        let nowHour = calendar.component(.hour, from: now)
        let slotStart = startOfSlot(containing: now, calendar: calendar)
        let slotStartText = slotStart.map { localization.shortTime($0) } ?? "n/a"
        print(
            "[MeetingListView] timezone=\(timeZone) now=\(localization.shortTime(now)) " +
            "hour=\(nowHour) slotStart=\(slotStartText) targetSlotID=\(targetID)"
        )
        #endif
    }
}
