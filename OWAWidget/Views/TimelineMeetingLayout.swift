import Foundation

struct TimelineMeetingCluster: Identifiable, Sendable, Hashable {
    let id: String
    let startDate: Date
    let endDate: Date
    let rowCount: Int
    let items: [TimelineMeetingItem]
}

struct TimelineMeetingItem: Identifiable, Sendable, Hashable {
    var id: String { event.id }

    let event: CalendarEvent
    let column: Int
    let columnCount: Int
    let offsetFraction: Double
    let widthFraction: Double
}

enum TimelineMeetingLayout {
    static func makeClusters(
        events: [CalendarEvent],
        minimumWidthFraction: Double = 0.08
    ) -> [TimelineMeetingCluster] {
        let sortedEvents = events.sorted {
            if $0.startDate != $1.startDate { return $0.startDate < $1.startDate }
            if $0.endDate != $1.endDate { return $0.endDate < $1.endDate }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }

        var clusters: [[CalendarEvent]] = []
        var currentCluster: [CalendarEvent] = []
        var currentClusterEnd: Date?

        for event in sortedEvents {
            guard let end = currentClusterEnd else {
                currentCluster = [event]
                currentClusterEnd = event.endDate
                continue
            }

            if event.startDate < end {
                currentCluster.append(event)
                currentClusterEnd = max(end, event.endDate)
            } else {
                clusters.append(currentCluster)
                currentCluster = [event]
                currentClusterEnd = event.endDate
            }
        }

        if !currentCluster.isEmpty {
            clusters.append(currentCluster)
        }

        return clusters.map {
            makeCluster(events: $0, minimumWidthFraction: minimumWidthFraction)
        }
    }

    private static func makeCluster(
        events: [CalendarEvent],
        minimumWidthFraction: Double
    ) -> TimelineMeetingCluster {
        let startDate = events.map(\.startDate).min() ?? Date()
        let endDate = events.map(\.endDate).max() ?? startDate
        let clusterDuration = max(1, endDate.timeIntervalSince(startDate))
        let columnCount = max(1, events.count)

        let items = events.enumerated().map { column, event in
            let offset = max(0, event.startDate.timeIntervalSince(startDate) / clusterDuration)
            let rawWidth = max(0, event.endDate.timeIntervalSince(event.startDate) / clusterDuration)
            let width = min(max(rawWidth, minimumWidthFraction), 1 - offset)

            return TimelineMeetingItem(
                event: event,
                column: column,
                columnCount: columnCount,
                offsetFraction: offset,
                widthFraction: width
            )
        }

        return TimelineMeetingCluster(
            id: events.map(\.id).joined(separator: "|"),
            startDate: startDate,
            endDate: endDate,
            rowCount: 1,
            items: items
        )
    }
}
