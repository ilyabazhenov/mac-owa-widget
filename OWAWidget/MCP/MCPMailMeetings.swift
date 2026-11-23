import Foundation

/// What the mail tools take from the calendar to show a meeting message as the mail window does:
/// which meeting it is, the user's answer, what else is on at that time. `MCPCalendarTools` is
/// the real one.
@MainActor
protocol MCPMeetingCalendar: AnyObject {
    /// The synced meetings plus those the MCP tools loaded beyond the sync window and still hold.
    var knownMeetings: [CalendarEvent] { get }
    /// The period every meeting of the synced calendar is known for (`coverage`).
    var knownCoverage: DateInterval? { get }
    /// A meeting as list_events shows it.
    func meetingSummary(_ event: CalendarEvent, coder: MCPDateCoder) -> [String: JSONValue]
}

/// What `respond_to_meeting` takes from the mailbox to answer an invitation by its `message_id`.
@MainActor
protocol MCPMeetingMail: AnyObject {
    /// The message behind `handle` (a `message_id` or a full id), read from the mailbox: one
    /// request of the shared budget. Throws `MCPToolError` as the mail tools refuse (mail off,
    /// unknown id, Exchange errors).
    func meetingMessage(_ handle: String, accountID: String?) async throws -> (message: MailMessage, accountID: UUID)
}

/// Links meeting messages in mail to the calendar.
enum MCPMailMeetings {
    /// The calendar meeting a meeting message is about. By the message's `AssociatedCalendarItemId`
    /// first (a one-off meeting's own id); then, for a series (whose messages point at the series,
    /// which the calendar view never lists) and for ids that did not match, the meeting of the same
    /// account with the message's time and title — a cancellation's subject has a prefix
    /// ("Canceled: …", "Отменено: …"), so after a colon the title only has to end it; a shorter
    /// title that merely ends the subject ("Sync" in "Weekly sync") is another meeting.
    static func event(for meeting: MailMeetingInfo, subject: String, accountID: UUID, in events: [CalendarEvent]) -> CalendarEvent? {
        let own = events.filter { $0.accountID == accountID }
        if let id = meeting.associatedCalendarItemID, let exact = own.first(where: { $0.id == id }) {
            return exact
        }
        guard let start = meeting.start, let end = meeting.end else { return nil }
        let wanted = MailVIP.normalized(subject)
        guard !wanted.isEmpty else { return nil }
        let sameTime = own.filter { $0.startDate == start && $0.endDate == end }
        return sameTime.first { candidate in
            let normalized = MailVIP.normalized(candidate.title)
            return !normalized.isEmpty && (normalized == wanted || wanted.hasSuffix(": " + normalized) || wanted.hasSuffix(":" + normalized))
        }
    }

    /// The user's other meetings sharing time with `interval` (half-open intervals): not the
    /// meeting itself (nor its copy in another calendar), not cancelled, declined or all-day ones.
    static func conflicts(with interval: DateInterval, excluding event: CalendarEvent?, in events: [CalendarEvent]) -> [CalendarEvent] {
        var seen = Set<String>()
        return events
            .filter { other in
                guard other.id != event?.id, !other.isAllDay, !other.isEffectivelyCancelled, other.responseType != .declined else { return false }
                if let uid = event?.icalUID, other.icalUID == uid { return false }
                return other.startDate < interval.end && interval.start < other.endDate
            }
            .filter { seen.insert($0.id).inserted }
            .sorted { ($0.startDate, $0.endDate, $0.title) < ($1.startDate, $1.endDate, $1.title) }
    }

    /// The kind every message of the conversation has, when they are all meeting messages of one
    /// kind (all invitations, all answers or all cancellations).
    static func uniformMeetingKind(_ conversation: MailConversationSummary) -> MailItemKind? {
        let kinds = Set(conversation.itemClasses.map { MailItemKind(itemClass: $0) })
        guard kinds.count == 1, let kind = kinds.first, kind.isMeetingMessage else { return nil }
        return kind
    }
}
