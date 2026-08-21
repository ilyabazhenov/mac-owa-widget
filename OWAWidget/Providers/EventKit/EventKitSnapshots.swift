import Foundation

/// Plain, `Sendable` value types mirroring the parts of EventKit this app reads.
///
/// EventKit's own classes (`EKEvent`, `EKCalendar`, `EKParticipant`) are reference types tied to
/// the `EKEventStore` that produced them, and touching one requires calendar access — which means
/// a TCC prompt. `swift test` is a mandatory gate before `make release-package`, and a prompt
/// there would hang packaging exactly the way a Keychain dialog does. Snapshotting at the store
/// boundary keeps every line worth testing (identity, join links, RSVP state) reachable from
/// tests that never construct an event store.

enum EventKitAccessStatus: Sendable, Hashable {
    case notDetermined
    case restricted
    case denied
    /// Read access granted. On macOS 13 this is the deprecated `.authorized`.
    case fullAccess
    /// macOS 14+ can grant write-only access, which is useless for reading a calendar.
    case writeOnly

    var canRead: Bool { self == .fullAccess }
}

enum EventKitEventStatus: Sendable, Hashable {
    case none, confirmed, tentative, canceled
}

enum EventKitParticipantRole: Sendable, Hashable {
    case unknown, required, optional, chair, nonParticipant
}

enum EventKitParticipantStatus: Sendable, Hashable {
    case unknown, pending, accepted, declined, tentative, delegated, completed, inProcess
}

struct EventKitParticipantSnapshot: Sendable, Hashable {
    let name: String?
    let email: String?
    let isCurrentUser: Bool
    let role: EventKitParticipantRole
    let status: EventKitParticipantStatus

    init(
        name: String?,
        email: String?,
        isCurrentUser: Bool,
        role: EventKitParticipantRole,
        status: EventKitParticipantStatus
    ) {
        self.name = name
        self.email = email
        self.isCurrentUser = isCurrentUser
        self.role = role
        self.status = status
    }
}

struct EventKitCalendarSnapshot: Sendable, Hashable, Identifiable {
    let identifier: String
    let title: String
    let sourceIdentifier: String
    let sourceTitle: String
    let allowsModifications: Bool

    var id: String { identifier }
}

struct EventKitEventSnapshot: Sendable, Hashable {
    let eventIdentifier: String?
    let externalIdentifier: String?
    let calendarIdentifier: String
    let calendarTitle: String
    let title: String?
    let startDate: Date
    let endDate: Date
    let isAllDay: Bool
    /// Start of the *original* occurrence for a recurring event; `nil` for one-off events.
    ///
    /// This is the only thing separating instances of a series: EventKit hands every occurrence
    /// the same `eventIdentifier`, so without it a weekly stand-up collapses into a single event
    /// in the cache and on the timeline.
    let occurrenceDate: Date?
    let hasRecurrenceRules: Bool
    let status: EventKitEventStatus
    let url: URL?
    let location: String?
    let notes: String?
    let organizer: EventKitParticipantSnapshot?
    let attendees: [EventKitParticipantSnapshot]

    init(
        eventIdentifier: String?,
        externalIdentifier: String? = nil,
        calendarIdentifier: String,
        calendarTitle: String = "",
        title: String?,
        startDate: Date,
        endDate: Date,
        isAllDay: Bool = false,
        occurrenceDate: Date? = nil,
        hasRecurrenceRules: Bool = false,
        status: EventKitEventStatus = .confirmed,
        url: URL? = nil,
        location: String? = nil,
        notes: String? = nil,
        organizer: EventKitParticipantSnapshot? = nil,
        attendees: [EventKitParticipantSnapshot] = []
    ) {
        self.eventIdentifier = eventIdentifier
        self.externalIdentifier = externalIdentifier
        self.calendarIdentifier = calendarIdentifier
        self.calendarTitle = calendarTitle
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.isAllDay = isAllDay
        self.occurrenceDate = occurrenceDate
        self.hasRecurrenceRules = hasRecurrenceRules
        self.status = status
        self.url = url
        self.location = location
        self.notes = notes
        self.organizer = organizer
        self.attendees = attendees
    }
}
