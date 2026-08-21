import Foundation

/// Turns EventKit snapshots into the app's `CalendarEvent`. Pure and free of EventKit types, so
/// every rule below is reachable from tests.
struct EventKitEventMapper: Sendable {
    private let detector: MeetingURLDetector

    init(detector: MeetingURLDetector = MeetingURLDetector()) {
        self.detector = detector
    }

    func map(_ snapshot: EventKitEventSnapshot, accountID: UUID) -> CalendarEvent? {
        let title = (snapshot.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard snapshot.endDate >= snapshot.startDate else { return nil }

        let (joinURL, platform) = resolveJoinURL(from: snapshot)
        let attendees = snapshot.attendees.map(Self.mapAttendee)
        let isOrganizer = snapshot.organizer?.isCurrentUser ?? false
        let notes = snapshot.notes?.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = (notes?.isEmpty == false) ? notes : nil

        return CalendarEvent(
            id: Self.identity(for: snapshot),
            title: title,
            startDate: snapshot.startDate,
            endDate: snapshot.endDate,
            location: snapshot.location?.isEmpty == false ? snapshot.location : nil,
            bodyPreview: body,
            joinURL: joinURL,
            platform: platform,
            isAllDay: snapshot.isAllDay,
            organizer: snapshot.organizer?.name ?? snapshot.organizer?.email,
            attendees: attendees.map(\.name).filter { !$0.isEmpty },
            accountID: accountID,
            isCancelled: snapshot.status == .canceled,
            isOrganizer: isOrganizer,
            // EventKit has no equivalent of Exchange categories, so meeting accent colours fall
            // back to their default. Calendar colours would be the natural source, but they are
            // per-calendar rather than per-event and would paint every row the same.
            categories: [],
            responseType: Self.responseType(for: snapshot, isOrganizer: isOrganizer),
            changeKey: nil,
            instanceKey: nil,
            // EventKit hands over participants and the full note in the same pass as the event
            // itself, so there is nothing left for `fetchDetails` to load lazily. Filling both
            // here makes `CalendarService.loadDetails` serve them straight from cache.
            detailedAttendees: attendees,
            fullBody: body,
            fullBodyHTML: nil
        )
    }

    /// Stable identity for one occurrence.
    ///
    /// `eventIdentifier` alone is not enough: every instance of a recurring series carries the
    /// same one. Pinning the original occurrence start (not the current start) keeps the identity
    /// stable when a single instance is dragged to another time.
    static func identity(for snapshot: EventKitEventSnapshot) -> String {
        let base = snapshot.eventIdentifier
            ?? snapshot.externalIdentifier
            ?? snapshot.calendarIdentifier
        let anchor = snapshot.occurrenceDate ?? snapshot.startDate
        return "\(base)|\(Int(anchor.timeIntervalSinceReferenceDate.rounded()))"
    }

    /// Where the join link comes from, in order of trust.
    ///
    /// Deliberately different from the OWA provider, which trusts its dedicated
    /// `JoinOnlineMeetingUrl` field first. EventKit's `url` is a free-form field with no promise
    /// of being a meeting link, while Google — the main reason this provider exists — leaves it
    /// empty and puts the Meet link in the note. So a *recognised* platform anywhere wins over an
    /// unrecognised `url`, which is only used as a last resort.
    private func resolveJoinURL(from snapshot: EventKitEventSnapshot) -> (URL?, MeetingPlatform) {
        var sources: [String] = []
        if let url = snapshot.url?.absoluteString, !url.isEmpty { sources.append(url) }
        if let location = snapshot.location, !location.isEmpty { sources.append(location) }
        if let notes = snapshot.notes, !notes.isEmpty { sources.append(notes) }

        for source in sources {
            if let detected = detector.detect(in: source) {
                return (detected.url, detected.platform)
            }
        }

        if let url = snapshot.url?.absoluteString,
           let safe = MeetingURLOpener.safeURL(fromString: url) {
            return (safe, .generic)
        }
        return (nil, .generic)
    }

    private static func mapAttendee(_ participant: EventKitParticipantSnapshot) -> EventAttendee {
        EventAttendee(
            name: participant.name ?? participant.email ?? "",
            email: participant.email,
            kind: participant.role == .optional ? .optional : .required,
            response: responseType(for: participant.status)
        )
    }

    private static func responseType(
        for snapshot: EventKitEventSnapshot,
        isOrganizer: Bool
    ) -> MeetingResponseType {
        if isOrganizer { return .organizer }
        guard let me = snapshot.attendees.first(where: { $0.isCurrentUser }) else {
            return .notResponded
        }
        return responseType(for: me.status)
    }

    private static func responseType(for status: EventKitParticipantStatus) -> MeetingResponseType {
        switch status {
        case .accepted, .completed: .accepted
        case .declined: .declined
        case .tentative, .inProcess: .tentative
        case .pending, .unknown, .delegated: .notResponded
        }
    }
}
