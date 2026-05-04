import Foundation

struct HourSlotMeetingItem: Identifiable, Sendable, Hashable {
    var id: String { event.id }

    let event: CalendarEvent
}

struct DayHourSlot: Identifiable, Sendable, Hashable {
    let startDate: Date
    let endDate: Date
    let items: [HourSlotMeetingItem]

    var id: String { "\(startDate.timeIntervalSince1970)" }
}

enum TimelineMeetingLayout {
    static func makeHourSlots(
        events: [CalendarEvent],
        sectionDate: Date,
        calendar: Calendar = .current,
        startHour: Int = 8,
        endHour: Int = 22
    ) -> [DayHourSlot] {
        let dayStart = calendar.startOfDay(for: sectionDate)
        let sortedEvents = events.sorted {
            if $0.startDate != $1.startDate { return $0.startDate < $1.startDate }
            if $0.endDate != $1.endDate { return $0.endDate < $1.endDate }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }

        return (startHour..<endHour).compactMap { hour in
            guard
                let slotStart = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: dayStart),
                let slotEnd = calendar.date(byAdding: .hour, value: 1, to: slotStart)
            else {
                return nil
            }

            let items = sortedEvents
                .filter { event in
                    event.startDate < slotEnd && event.endDate > slotStart
                }
                .map { HourSlotMeetingItem(event: $0) }

            return DayHourSlot(startDate: slotStart, endDate: slotEnd, items: items)
        }
    }
}
