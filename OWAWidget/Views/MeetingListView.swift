import SwiftUI

struct MeetingListView: View {
    let sections: [(label: String, date: Date, events: [CalendarEvent])]
    @EnvironmentObject private var localization: LocalizationService
    @State private var hasAutoScrolledToCurrentSlot = false

    private let timeColumnWidth: CGFloat = 56

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

        return VStack(spacing: 10) {
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

        return HStack(alignment: .top, spacing: 10) {
            Text(localization.shortTime(slot.startDate))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: timeColumnWidth, alignment: .trailing)
                .padding(.top, 9)

            VStack(spacing: 6) {
                if slot.items.isEmpty {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .controlBackgroundColor).opacity(0.28))
                        .overlay {
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color(nsColor: .separatorColor).opacity(0.25), lineWidth: 1)
                        }
                        .frame(height: 28)
                } else {
                    ForEach(slot.items) { item in
                        TimelineMeetingBlockView(event: item.event)
                            .frame(height: 44)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isCurrentSlot ? Color.accentColor.opacity(0.08) : .clear)
        )
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
        guard let slotStart = calendar.dateInterval(of: .hour, for: now)?.start else {
            return nil
        }
        return slotID(for: section.date, slotStart: slotStart)
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
        let slotStart = calendar.dateInterval(of: .hour, for: now)?.start
        let slotStartText = slotStart.map { localization.shortTime($0) } ?? "n/a"
        print(
            "[MeetingListView] timezone=\(timeZone) now=\(localization.shortTime(now)) " +
            "hour=\(nowHour) slotStart=\(slotStartText) targetSlotID=\(targetID)"
        )
        #endif
    }
}
