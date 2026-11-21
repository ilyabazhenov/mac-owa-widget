import Foundation

/// What changed in one account's calendar between two syncs, for `get_changes`.
///
/// The sync window slides with time, so a meeting entering or leaving it is not a change: a
/// meeting counts as new only when the older sync would have returned it (it overlaps the older
/// window), and as removed only when the newer one would have (it overlaps the newer window).
enum CalendarChangeDetector {
    static func changes(
        old: [CalendarEvent],
        oldWindow: DateInterval,
        new: [CalendarEvent],
        newWindow: DateInterval
    ) -> [MCPCalendarChange] {
        let oldByID = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let newIDs = Set(new.map(\.id))
        var changes: [MCPCalendarChange] = []
        for event in new {
            guard let before = oldByID[event.id] else {
                if overlaps(event, oldWindow) { changes.append(MCPCalendarChange(kind: .created, event: event)) }
                continue
            }
            let fields = changedFields(before, event)
            if !fields.isEmpty { changes.append(MCPCalendarChange(kind: .updated, event: event, fields: fields)) }
        }
        for event in old where !newIDs.contains(event.id) && overlaps(event, newWindow) {
            changes.append(MCPCalendarChange(kind: .removed, event: event))
        }
        return changes.sorted { $0.event.startDate < $1.event.startDate }
    }

    /// `other`: Exchange changed the meeting (its `ChangeKey`) in a way the list does not show —
    /// on a meeting the user organizes, usually an attendee's answer.
    static func changedFields(_ old: CalendarEvent, _ new: CalendarEvent) -> [String] {
        var fields: [String] = []
        if old.startDate != new.startDate || old.endDate != new.endDate || old.isAllDay != new.isAllDay { fields.append("time") }
        if old.title != new.title { fields.append("title") }
        if normalized(old.location) != normalized(new.location) { fields.append("location") }
        if Set(old.attendees) != Set(new.attendees) { fields.append("attendees") }
        if old.responseType != new.responseType { fields.append("my_response") }
        if old.isEffectivelyCancelled != new.isEffectivelyCancelled { fields.append("cancelled") }
        if fields.isEmpty, let key = new.changeKey, old.changeKey != key { fields.append("other") }
        return fields
    }

    private static func overlaps(_ event: CalendarEvent, _ window: DateInterval) -> Bool {
        event.endDate > window.start && event.startDate < window.end
            || event.startDate == event.endDate && window.contains(event.startDate)
    }

    private static func normalized(_ text: String?) -> String {
        (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
