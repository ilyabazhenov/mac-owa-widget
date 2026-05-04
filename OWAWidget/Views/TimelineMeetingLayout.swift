import Foundation

struct HourSlotMeetingItem: Identifiable, Sendable, Hashable {
    var id: String { event.id }

    let event: CalendarEvent
    let laneIndex: Int
    let laneCount: Int
}

struct DayHourSlot: Identifiable, Sendable, Hashable {
    let startDate: Date
    let endDate: Date
    let items: [HourSlotMeetingItem]

    var id: String { "\(startDate.timeIntervalSince1970)" }
}

struct TimelineBlockMetrics: Sendable, Hashable {
    let topOffset: Double
    let height: Double
}

struct TimelineCardFrame: Sendable, Hashable {
    let xOffset: Double
    let yOffset: Double
    let width: Double
    let height: Double

    var centerX: Double { xOffset + width / 2 }
    var centerY: Double { yOffset + height / 2 }
}

enum TimelineMeetingLayout {
    private static let slotDurationMinutes = 30

    static func makeHourSlots(
        events: [CalendarEvent],
        sectionDate: Date,
        calendar: Calendar = .current,
        startHour: Int = 0,
        endHour: Int = 24,
        referenceDate: Date? = nil
    ) -> [DayHourSlot] {
        let dayStart = calendar.startOfDay(for: sectionDate)
        let slotBounds = adjustedHourBounds(
            sectionDate: sectionDate,
            calendar: calendar,
            startHour: startHour,
            endHour: endHour,
            referenceDate: referenceDate
        )
        let sortedEvents = events.sorted {
            if $0.startDate != $1.startDate { return $0.startDate < $1.startDate }
            if $0.endDate != $1.endDate { return $0.endDate < $1.endDate }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
        let laneMetadataByID = makeLaneMetadata(events: sortedEvents)

        guard
            let sectionStart = calendar.date(byAdding: .hour, value: slotBounds.start, to: dayStart),
            let sectionEnd = calendar.date(byAdding: .hour, value: slotBounds.end, to: dayStart),
            sectionStart < sectionEnd
        else {
            return []
        }

        var slotsByIndex: [(index: Int, start: Date, end: Date)] = []
        var slotStart = sectionStart
        var slotIndex = 0
        while slotStart < sectionEnd {
            guard let slotEnd = calendar.date(byAdding: .minute, value: slotDurationMinutes, to: slotStart) else {
                break
            }
            slotsByIndex.append((index: slotIndex, start: slotStart, end: slotEnd))
            slotStart = slotEnd
            slotIndex += 1
        }

        var itemsBySlot: [Int: [HourSlotMeetingItem]] = Dictionary(
            uniqueKeysWithValues: slotsByIndex.map { ($0.index, []) }
        )

        for event in sortedEvents {
            guard let targetSlot = slotsByIndex.first(where: { slot in
                event.startDate < slot.end && event.endDate > slot.start
            }) else {
                continue
            }
            let laneMetadata = laneMetadataByID[event.id] ?? (laneIndex: 0, laneCount: 1)
            itemsBySlot[targetSlot.index, default: []].append(
                HourSlotMeetingItem(
                    event: event,
                    laneIndex: laneMetadata.laneIndex,
                    laneCount: laneMetadata.laneCount
                )
            )
        }

        return slotsByIndex.map { slot in
            DayHourSlot(
                startDate: slot.start,
                endDate: slot.end,
                items: itemsBySlot[slot.index] ?? []
            )
        }
    }

    static func blockMetrics(
        for event: CalendarEvent,
        gridStart: Date,
        pointsPerMinute: Double,
        verticalGap: Double,
        minimumHeight: Double = 38,
        maximumHeight: Double = 96
    ) -> TimelineBlockMetrics {
        let gap = max(0, verticalGap)
        let minutesFromStart = max(0, event.startDate.timeIntervalSince(gridStart) / 60)
        let rawTopOffset = minutesFromStart * pointsPerMinute
        let durationHeight = max(0, event.duration / 60 * pointsPerMinute)
        let blockHeight = max(
            0,
            max(minimumHeight - gap, min(maximumHeight, durationHeight - gap))
        )

        return TimelineBlockMetrics(
            topOffset: rawTopOffset + gap / 2,
            height: blockHeight
        )
    }

    static func cardFrame(
        for event: CalendarEvent,
        laneIndex: Int,
        laneCount: Int,
        gridStart: Date,
        leftInset: Double,
        cardAreaWidth: Double,
        laneSpacing: Double,
        pointsPerMinute: Double,
        verticalGap: Double
    ) -> TimelineCardFrame {
        let safeLaneCount = max(1, laneCount)
        let safeLaneIndex = min(max(0, laneIndex), safeLaneCount - 1)
        let safeLaneSpacing = max(0, laneSpacing)
        let availableWidth = max(0, cardAreaWidth)
        let cardWidth = max(
            0,
            (availableWidth - Double(safeLaneCount - 1) * safeLaneSpacing) / Double(safeLaneCount)
        )
        let xOffset = leftInset + Double(safeLaneIndex) * (cardWidth + safeLaneSpacing)
        let metrics = blockMetrics(
            for: event,
            gridStart: gridStart,
            pointsPerMinute: pointsPerMinute,
            verticalGap: verticalGap
        )

        return TimelineCardFrame(
            xOffset: xOffset,
            yOffset: metrics.topOffset,
            width: cardWidth,
            height: metrics.height
        )
    }

    private static func adjustedHourBounds(
        sectionDate: Date,
        calendar: Calendar,
        startHour: Int,
        endHour: Int,
        referenceDate: Date?
    ) -> (start: Int, end: Int) {
        guard
            let referenceDate,
            calendar.isDate(referenceDate, inSameDayAs: sectionDate)
        else {
            return (startHour, endHour)
        }

        let currentHour = calendar.component(.hour, from: referenceDate)
        let safeStart = max(0, min(23, startHour))
        let safeEnd = max(safeStart + 1, min(24, endHour))
        let adjustedStart = min(safeStart, currentHour)
        let adjustedEnd = max(safeEnd, currentHour + 1)
        return (adjustedStart, adjustedEnd)
    }

    static func makeOverlapClusters(
        items: [HourSlotMeetingItem]
    ) -> [[HourSlotMeetingItem]] {
        guard !items.isEmpty else { return [] }

        let sortedItems = items.sorted {
            if $0.event.startDate != $1.event.startDate { return $0.event.startDate < $1.event.startDate }
            if $0.event.endDate != $1.event.endDate { return $0.event.endDate < $1.event.endDate }
            return $0.event.title.localizedCaseInsensitiveCompare($1.event.title) == .orderedAscending
        }

        var clusters: [[HourSlotMeetingItem]] = []
        var currentCluster: [HourSlotMeetingItem] = []
        var currentClusterMaxEnd: Date?

        for item in sortedItems {
            guard let clusterEnd = currentClusterMaxEnd else {
                currentCluster = [item]
                currentClusterMaxEnd = item.event.endDate
                continue
            }

            if item.event.startDate < clusterEnd {
                currentCluster.append(item)
                if item.event.endDate > clusterEnd {
                    currentClusterMaxEnd = item.event.endDate
                }
            } else {
                clusters.append(currentCluster)
                currentCluster = [item]
                currentClusterMaxEnd = item.event.endDate
            }
        }

        if !currentCluster.isEmpty {
            clusters.append(currentCluster)
        }

        return clusters
    }

    private static func makeLaneMetadata(
        events: [CalendarEvent]
    ) -> [String: (laneIndex: Int, laneCount: Int)] {
        guard !events.isEmpty else { return [:] }

        let clusters = makeEventClusters(events: events)
        var metadata: [String: (laneIndex: Int, laneCount: Int)] = [:]

        for cluster in clusters {
            let laneAssignments = assignLanes(for: cluster)
            let laneCount = max(1, laneAssignments.values.max().map { $0 + 1 } ?? 1)

            for event in cluster {
                let laneIndex = laneAssignments[event.id] ?? 0
                metadata[event.id] = (laneIndex: laneIndex, laneCount: laneCount)
            }
        }

        return metadata
    }

    private static func makeEventClusters(events: [CalendarEvent]) -> [[CalendarEvent]] {
        guard !events.isEmpty else { return [] }

        var clusters: [[CalendarEvent]] = []
        var currentCluster: [CalendarEvent] = []
        var currentClusterMaxEnd: Date?

        for event in events {
            guard let clusterEnd = currentClusterMaxEnd else {
                currentCluster = [event]
                currentClusterMaxEnd = event.endDate
                continue
            }

            if event.startDate < clusterEnd {
                currentCluster.append(event)
                if event.endDate > clusterEnd {
                    currentClusterMaxEnd = event.endDate
                }
            } else {
                clusters.append(currentCluster)
                currentCluster = [event]
                currentClusterMaxEnd = event.endDate
            }
        }

        if !currentCluster.isEmpty {
            clusters.append(currentCluster)
        }

        return clusters
    }

    private static func assignLanes(for events: [CalendarEvent]) -> [String: Int] {
        var laneEndDates: [Date] = []
        var assignments: [String: Int] = [:]

        for event in events {
            if let laneIndex = laneEndDates.firstIndex(where: { $0 <= event.startDate }) {
                laneEndDates[laneIndex] = event.endDate
                assignments[event.id] = laneIndex
            } else {
                laneEndDates.append(event.endDate)
                assignments[event.id] = laneEndDates.count - 1
            }
        }

        return assignments
    }
}
