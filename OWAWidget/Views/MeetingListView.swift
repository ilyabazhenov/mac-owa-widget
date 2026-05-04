import SwiftUI

struct MeetingListView: View {
    let sections: [(label: String, date: Date, events: [CalendarEvent])]
    @EnvironmentObject private var localization: LocalizationService
    @State private var hasAutoScrolledToCurrentSlot = false

    private let timeColumnWidth: CGFloat = 56
    private let timelinePointsPerMinute: CGFloat = 44.0 / 60.0
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

    private func hourlySection(
        section: (label: String, date: Date, events: [CalendarEvent])
    ) -> some View {
        let slots = TimelineMeetingLayout.makeHourSlots(
            events: section.events,
            sectionDate: section.date,
            referenceDate: Date()
        )

        return VStack(spacing: 0) {
            ForEach(slots) { slot in
                slotRow(slot)
                    .id(slotID(for: section.date, slotStart: slot.startDate))
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    private func slotRow(_ slot: DayHourSlot) -> some View {
        let isCurrentSlot = isCurrentTimeSlot(slot)
        let clusterLayouts = makeClusterLayouts(for: slot)
        let isHalfHourSlot = Calendar.current.component(.minute, from: slot.startDate) == 30
        let showTimeLabel = !isHalfHourSlot
        let isHourSlot = !isHalfHourSlot
        let slotHeight = slotVisualHeight(for: slot)

        return HStack(alignment: .top, spacing: 10) {
            Text(showTimeLabel ? localization.shortTime(slot.startDate) : "")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: timeColumnWidth, alignment: .trailing)
                .padding(.top, 9)

            ZStack(alignment: .topLeading) {
                if slot.items.isEmpty {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .controlBackgroundColor).opacity(0.24))
                        .overlay {
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color(nsColor: .separatorColor).opacity(0.22), lineWidth: 1)
                        }
                        .frame(height: slotHeight)
                } else {
                    ForEach(Array(clusterLayouts.enumerated()), id: \.offset) { _, layout in
                        overlapClusterRow(layout.cluster, rowHeight: layout.height)
                            .frame(height: layout.height)
                            .offset(y: layout.topOffset)
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: slotHeight, maxHeight: slotHeight, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isCurrentSlot ? Color.accentColor.opacity(0.08) : .clear)
        )
        .overlay(alignment: .top) {
            if isHourSlot {
                Rectangle()
                    .fill(Color(nsColor: .separatorColor).opacity(0.4))
                    .frame(height: 1)
                    .padding(.leading, timeColumnWidth + 10)
            }
        }
    }

    private func makeClusterLayouts(for slot: DayHourSlot) -> [ClusterLayout] {
        let clusters = TimelineMeetingLayout.makeOverlapClusters(items: slot.items)
        var layouts: [ClusterLayout] = []

        for cluster in clusters {
            guard !cluster.isEmpty else { continue }

            let earliestStart = cluster.map(\.event.startDate).min() ?? slot.startDate
            let minutesFromSlotStart = max(0, earliestStart.timeIntervalSince(slot.startDate) / 60)
            let topOffset = CGFloat(minutesFromSlotStart) * timelinePointsPerMinute
            let rowHeight = cluster
                .map { blockHeight(for: $0.event) }
                .max() ?? 30

            layouts.append(
                ClusterLayout(
                    cluster: cluster,
                    topOffset: topOffset,
                    height: rowHeight
                )
            )
        }

        return layouts
    }

    private func overlapClusterRow(_ cluster: [HourSlotMeetingItem], rowHeight: CGFloat) -> some View {
        GeometryReader { geometry in
            let laneSpacing: CGFloat = 6
            ZStack(alignment: .topLeading) {
                ForEach(cluster) { item in
                    let laneCount = max(1, item.laneCount)
                    let laneWidth = max(
                        0,
                        (geometry.size.width - CGFloat(laneCount - 1) * laneSpacing) / CGFloat(laneCount)
                    )
                    let xOffset = CGFloat(item.laneIndex) * (laneWidth + laneSpacing)

                    TimelineMeetingBlockView(event: item.event)
                        .frame(width: laneWidth, height: rowHeight, alignment: .leading)
                        .offset(x: xOffset, y: 0)
                }
            }
        }
    }

    private func blockHeight(for event: CalendarEvent) -> CGFloat {
        let minutes = max(10, event.duration / 60)
        let dynamicHeight = CGFloat(minutes) * timelinePointsPerMinute
        return min(96, max(30, dynamicHeight))
    }

    private func slotVisualHeight(for slot: DayHourSlot) -> CGFloat {
        let minutes = max(1, slot.endDate.timeIntervalSince(slot.startDate) / 60)
        return CGFloat(minutes) * timelinePointsPerMinute
    }

    private struct ClusterLayout {
        let cluster: [HourSlotMeetingItem]
        let topOffset: CGFloat
        let height: CGFloat
    }

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
