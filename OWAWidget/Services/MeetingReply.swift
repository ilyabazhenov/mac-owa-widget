import Foundation

/// How an answer to an invitation goes out from the app's own interface: the detail card, the
/// invitation panel or the popover's inbox column.
struct MeetingReplyOptions: Equatable, Sendable {
    /// The whole series rather than the one occurrence.
    var series = false
    /// `false` keeps the answer in the user's calendar only: the organizer gets no email and
    /// keeps seeing "no response" (OWA's "Don't send a response").
    var notifyOrganizer = true
    /// Sent with the answer; dropped when the organizer is not told, since it has nowhere to go.
    var comment = ""

    static let commentLimit = 2000

    /// The comment that actually goes out: trimmed, and empty when nobody is told.
    var effectiveComment: String {
        guard notifyOrganizer else { return "" }
        return String(comment.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.commentLimit))
    }

    /// A plain answer to one occurrence, with an email and no comment, still goes through the
    /// long-proven EWS request; everything else needs OWA's `RespondToCalendarEvent`.
    var needsCalendarEventRequest: Bool {
        series || !notifyOrganizer || !effectiveComment.isEmpty
    }
}

/// The line shown after an answer went through: "Accepted · response sent",
/// "Accepted for the whole series · organizer not notified".
enum MeetingReplySummary {
    static func text(
        action: MeetingResponseAction,
        options: MeetingReplyOptions,
        tr: (String) -> String
    ) -> String {
        let verb: String
        switch action {
        case .accept: verb = tr("meeting.reply.done.accept")
        case .tentative: verb = tr("meeting.reply.done.tentative")
        case .decline: verb = tr("meeting.reply.done.decline")
        }
        let tail: String
        if !options.notifyOrganizer {
            tail = tr("meeting.reply.done.silent")
        } else if !options.effectiveComment.isEmpty {
            tail = tr("meeting.reply.done.sentWithComment")
        } else {
            tail = tr("meeting.reply.done.sent")
        }
        let scope = options.series ? " " + tr("meeting.reply.done.series") : ""
        return "\(verb)\(scope) · \(tail)"
    }
}

enum MeetingReplyScope {
    /// The scope the detail card starts with: the whole series while no occurrence of it has an
    /// answer yet (that is a fresh series invitation), otherwise the one occurrence, so a click
    /// does not overwrite answers already given across the series.
    static func defaultsToSeries(_ event: CalendarEvent, in events: [CalendarEvent]) -> Bool {
        guard event.isRecurring, let seriesID = event.seriesID else { return false }
        let occurrences = events.filter { $0.accountID == event.accountID && $0.seriesID == seriesID }
        guard !occurrences.isEmpty else { return event.responseType == .notResponded }
        return occurrences.allSatisfy { $0.responseType == .notResponded }
    }

    /// Whether the folded invitation row is one series: then a single series answer covers it.
    /// Rows fold by subject and organizer, so unrelated one-off meetings may share a row; those
    /// are answered one by one.
    static func isSingleSeries(_ events: [CalendarEvent]) -> Bool {
        guard events.count > 1, let first = events.first, let seriesID = first.seriesID else { return false }
        return events.allSatisfy { $0.accountID == first.accountID && $0.seriesID == seriesID }
    }
}
