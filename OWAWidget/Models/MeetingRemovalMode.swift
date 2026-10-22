import Foundation

/// What taking a meeting out of the calendar does to the other people in it.
enum MeetingRemovalMode: String, Sendable, Equatable {
    /// The user organises it: every attendee gets a cancellation, and it leaves their calendars.
    case cancelForAttendees
    /// The user was invited: the organizer gets a decline, and Exchange takes it off the calendar.
    case decline
    /// Only the user's own calendar changes and nobody is told: a meeting without attendees, one
    /// the organizer has already cancelled, or an invitation removed without an answer.
    case deleteSilently
}
