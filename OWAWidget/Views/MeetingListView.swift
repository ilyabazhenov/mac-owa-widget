import SwiftUI

struct MeetingListView: View {
    let sections: [(label: String, events: [CalendarEvent])]
    @EnvironmentObject private var localization: LocalizationService

    private let timeColumnWidth: CGFloat = 56
    private let laneHeight: CGFloat = 58
    private let blockHeight: CGFloat = 48
    private let clusterHeaderHeight: CGFloat = 28
    private let columnSpacing: CGFloat = 6

    var body: some View {
        if sections.allSatisfy({ $0.events.isEmpty }) {
            emptyState
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(sections.filter { !$0.events.isEmpty }, id: \.label) { section in
                        Section {
                            timelineSection(events: section.events)
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

    private func timelineSection(events: [CalendarEvent]) -> some View {
        let clusters = TimelineMeetingLayout.makeClusters(events: events)

        return VStack(spacing: 10) {
            ForEach(clusters) { cluster in
                timelineCluster(cluster)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    private func timelineCluster(_ cluster: TimelineMeetingCluster) -> some View {
        let height = clusterHeaderHeight + CGFloat(cluster.rowCount) * laneHeight + 12

        return GeometryReader { geometry in
            let timelineWidth = max(1, geometry.size.width - timeColumnWidth)

            ZStack(alignment: .topLeading) {
                clusterBackground

                HStack {
                    Text(clusterTitle(cluster))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.leading, 10)
                .padding(.trailing, 10)
                .frame(height: clusterHeaderHeight)

                timeRuler(cluster: cluster, timelineWidth: timelineWidth)
                    .offset(y: clusterHeaderHeight)

                ForEach(cluster.items) { item in
                    let gaps = CGFloat(max(0, item.columnCount - 1)) * columnSpacing
                    let blockWidth = max(1, (timelineWidth - gaps) / CGFloat(max(1, item.columnCount)))
                    let xOffset = timeColumnWidth + CGFloat(item.column) * (blockWidth + columnSpacing)
                    let yOffset = clusterHeaderHeight + 6

                    TimelineMeetingBlockView(event: item.event)
                        .frame(width: blockWidth, height: blockHeight)
                        .offset(x: xOffset, y: yOffset)
                }
            }
        }
        .frame(height: height)
    }

    private var clusterBackground: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.45))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 1)
            }
    }

    private func timeRuler(cluster: TimelineMeetingCluster, timelineWidth: CGFloat) -> some View {
        let rulerHeight = CGFloat(max(1, cluster.rowCount)) * laneHeight

        return ZStack(alignment: .topLeading) {
            ForEach([0.0, 0.5, 1.0], id: \.self) { fraction in
                Rectangle()
                    .fill(Color(nsColor: .separatorColor).opacity(fraction == 0 || fraction == 1 ? 0.45 : 0.22))
                    .frame(width: 1, height: rulerHeight)
                    .offset(x: timeColumnWidth + timelineWidth * fraction)
            }

            Text(localization.shortTime(cluster.startDate))
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: timeColumnWidth - 8, alignment: .trailing)
                .offset(x: 0, y: 6)

            Text(localization.shortTime(cluster.endDate))
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .trailing)
                .offset(x: timeColumnWidth + timelineWidth - 46, y: 6)

            ForEach(0..<max(1, cluster.rowCount), id: \.self) { row in
                Rectangle()
                    .fill(Color(nsColor: .separatorColor).opacity(0.18))
                    .frame(width: timelineWidth, height: 1)
                    .offset(x: timeColumnWidth, y: CGFloat(row) * laneHeight)
            }
        }
        .frame(width: timeColumnWidth + timelineWidth, height: rulerHeight, alignment: .topLeading)
    }

    private func clusterTitle(_ cluster: TimelineMeetingCluster) -> String {
        let start = localization.shortTime(cluster.startDate)
        let end = localization.shortTime(cluster.endDate)
        if cluster.items.count > 1 {
            return localization.tr("meeting.parallel.window", cluster.items.count, start, end)
        }
        return "\(start)–\(end)"
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
