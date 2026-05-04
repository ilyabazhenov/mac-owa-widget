import SwiftUI

struct MeetingListView: View {
    let sections: [(label: String, date: Date, events: [CalendarEvent])]
    @EnvironmentObject private var localization: LocalizationService

    private let timeColumnWidth: CGFloat = 56

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(sections, id: \.label) { section in
                    Section {
                        hourlySection(date: section.date, events: section.events)
                    } header: {
                        sectionHeader(section.label)
                    }
                }
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

    private func hourlySection(date: Date, events: [CalendarEvent]) -> some View {
        let slots = TimelineMeetingLayout.makeHourSlots(events: events, sectionDate: date)

        return VStack(spacing: 10) {
            ForEach(slots) { slot in
                slotRow(slot)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    private func slotRow(_ slot: DayHourSlot) -> some View {
        HStack(alignment: .top, spacing: 10) {
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
    }
}
