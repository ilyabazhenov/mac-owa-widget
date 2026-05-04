import SwiftUI

struct MeetingListView: View {
    let sections: [(label: String, events: [CalendarEvent])]
    @EnvironmentObject private var localization: LocalizationService

    var body: some View {
        if sections.allSatisfy({ $0.events.isEmpty }) {
            emptyState
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(sections.filter { !$0.events.isEmpty }, id: \.label) { section in
                        Section {
                            ForEach(section.events) { event in
                                MeetingRowView(event: event)
                                if event.id != section.events.last?.id {
                                    Divider()
                                        .padding(.leading, 74)
                                }
                            }
                        } header: {
                            sectionHeader(section.label)
                        }
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

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "calendar.badge.checkmark")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text(localization.tr("meeting.no.upcoming"))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }
}
