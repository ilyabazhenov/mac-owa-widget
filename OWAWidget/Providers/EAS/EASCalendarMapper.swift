import Foundation

/// Turns raw ActiveSync appointments into the app's ``CalendarEvent``.
///
/// Deliberately mirrors `OWACalendarProvider.mapItem` and `resolveJoinURL`, because the same
/// meeting reached over either protocol must land in the UI identically — otherwise switching
/// account types would change how meetings look and which ones offer a join button.
struct EASCalendarMapper {

    /// Exchange caps the preview `GetCalendarView` returns at 255 characters. Matching that
    /// keeps the two providers' events the same shape.
    private static let previewLimit = 255

    private let detector: MeetingURLDetector

    init(detector: MeetingURLDetector = MeetingURLDetector()) {
        self.detector = detector
    }

    /// Every event this item contributes to the window.
    ///
    /// One for a plain appointment; for a series, one per occurrence the rule produces — the
    /// server never sends those, so they are expanded here.
    func events(
        from item: EASCalendarItem,
        in window: DateInterval,
        accountID: UUID,
        fallbackZone: TimeZone = .current
    ) -> [CalendarEvent] {
        EASRecurrenceExpander.expand(item, in: window, fallbackZone: fallbackZone)
            .compactMap { event(from: item, occurrence: $0, accountID: accountID) }
    }

    /// Maps a single, non-recurring appointment.
    ///
    /// Returns `nil` when the item cannot become an event the rest of the app can reason
    /// about — no title, or no usable interval.
    func event(from item: EASCalendarItem, accountID: UUID) -> CalendarEvent? {
        guard let start = item.start, let end = item.end else { return nil }
        let occurrence = EASOccurrence(originalStart: start, start: start, end: end, exception: nil)
        return event(from: item, occurrence: occurrence, accountID: accountID)
    }

    /// Maps one occurrence, applying whatever the organiser changed about it.
    func event(
        from item: EASCalendarItem,
        occurrence: EASOccurrence,
        accountID: UUID
    ) -> CalendarEvent? {
        let effective = merged(item, with: occurrence.exception)
        guard let title = effective.subject, !title.isEmpty else { return nil }

        let (joinURL, platform) = resolveJoinURL(for: effective)
        let start = occurrence.start
        let end = occurrence.end

        return CalendarEvent(
            id: item.isRecurring
                ? Self.eventID(serverId: item.serverId, originalStart: occurrence.originalStart)
                : Self.eventID(serverId: item.serverId),
            title: title,
            startDate: start,
            // A zero-length appointment would be invisible in the timeline; give it a minute.
            endDate: end > start ? end : start.addingTimeInterval(60),
            location: effective.location,
            bodyPreview: preview(from: effective.bodyText),
            joinURL: joinURL,
            platform: platform,
            isAllDay: effective.isAllDay,
            organizer: effective.organizerName ?? effective.organizerEmail,
            attendees: effective.attendees.map { $0.name.isEmpty ? ($0.email ?? "") : $0.name }
                .filter { !$0.isEmpty },
            accountID: accountID,
            isCancelled: effective.isCancelled,
            isOrganizer: effective.isOrganizer,
            categories: effective.categories,
            responseType: Self.responseType(for: effective),
            // ActiveSync has no change key. The field is used as an opaque "this event can be
            // written to" flag and handed straight back to `respondToMeeting`, so the ServerId
            // serves both purposes and keeps the RSVP buttons enabled.
            changeKey: item.serverId,
            // Identifies which occurrence of a series this is, for callers that need to address
            // it on the server.
            instanceKey: item.isRecurring ? EASDate.format(occurrence.originalStart) : nil
        )
    }

    /// The series master overlaid with an occurrence's overrides. Fields the exception does not
    /// mention are inherited, which is what makes "just this once, in a different room" work.
    private func merged(_ item: EASCalendarItem, with exception: EASException?) -> EASCalendarItem {
        guard let exception else { return item }
        var merged = item
        if let subject = exception.subject { merged.subject = subject }
        if let location = exception.location { merged.location = location }
        if let isAllDay = exception.isAllDay { merged.isAllDay = isAllDay }
        if let body = exception.bodyText { merged.bodyText = body }
        if let status = exception.meetingStatus { merged.meetingStatus = status }
        if let response = exception.responseType { merged.responseType = response }
        if let link = exception.onlineMeetingConfLink { merged.onlineMeetingConfLink = link }
        if let attendees = exception.attendees { merged.attendees = attendees }
        return merged
    }

    /// Stable across syncs, which the whole app depends on: deduplication, the optimistic RSVP
    /// patch and the detail cache all key on it.
    static func eventID(serverId: String) -> String { serverId }

    /// For one occurrence of a series. Keyed on the occurrence's *original* start, so moving a
    /// single occurrence does not change its identity.
    static func eventID(serverId: String, originalStart: Date) -> String {
        "\(serverId)|\(Int(originalStart.timeIntervalSince1970))"
    }

    // MARK: Pieces

    private func preview(from body: String?) -> String? {
        guard let body else { return nil }
        let collapsed = body.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return String(collapsed.prefix(Self.previewLimit))
    }

    /// Same precedence the OWA provider uses: the dedicated field, then the location, then the
    /// body. Everything goes through `MeetingURLOpener.safeURL` so a `file://` or custom-scheme
    /// link never becomes a clickable join button.
    private func resolveJoinURL(for item: EASCalendarItem) -> (URL?, MeetingPlatform) {
        for candidate in [item.onlineMeetingConfLink, item.onlineMeetingExternalLink] {
            if let candidate, !candidate.isEmpty,
               let url = MeetingURLOpener.safeURL(fromString: candidate) {
                return (url, detector.detectPlatform(from: candidate))
            }
        }

        if let location = item.location, !location.isEmpty,
           let detected = detector.detect(in: location) {
            return (detected.url, detected.platform)
        }

        if let body = item.bodyText, !body.isEmpty,
           let detected = detector.detect(in: body) {
            return (detected.url, detected.platform)
        }

        return (nil, .generic)
    }

    /// `calendar:ResponseType` — 1 organizer, 2 tentative, 3 accepted, 4 declined,
    /// 5 not responded. It is absent on plain appointments and on protocol versions below 14.0,
    /// so the meeting status is the fallback for "did I organise this".
    static func responseType(for item: EASCalendarItem) -> MeetingResponseType {
        if item.isOrganizer { return .organizer }
        switch item.responseType {
        case 1: return .organizer
        case 2: return .tentative
        case 3: return .accepted
        case 4: return .declined
        default: return .notResponded
        }
    }
}

// MARK: - Details

extension EASCalendarMapper {

    /// The attendee list and agenda the detail panel shows.
    ///
    /// `instanceKey` names one occurrence of a series; when the organiser changed that
    /// occurrence specifically, its overrides win over the series master.
    static func details(from item: EASCalendarItem, instanceKey: String?) -> CalendarEventDetails {
        let override = instanceKey
            .flatMap(EASDate.parse)
            .flatMap { original in
                item.exceptions.first { $0.originalStart == original }
            }

        let attendees = (override?.attendees ?? item.attendees).map(eventAttendee)
        let body = override?.bodyText ?? item.bodyText

        return CalendarEventDetails(
            attendees: attendees,
            body: body,
            // ActiveSync is asked for plain text, so there is no markup to rebuild tables from.
            bodyHTML: nil
        )
    }

    private static func eventAttendee(_ attendee: EASAttendee) -> EventAttendee {
        EventAttendee(
            name: attendee.name.isEmpty ? (attendee.email ?? "") : attendee.name,
            email: attendee.email,
            // `AttendeeType` — 1 required, 2 optional, 3 resource. A room is not an optional
            // guest, so anything that is not explicitly optional counts as required.
            kind: attendee.type == 2 ? .optional : .required,
            response: attendeeResponse(attendee.status)
        )
    }

    /// `AttendeeStatus` — 0 unknown, 2 tentative, 3 accepted, 4 declined, 5 not responded.
    static func attendeeResponse(_ status: Int?) -> MeetingResponseType {
        switch status {
        case 2: return .tentative
        case 3: return .accepted
        case 4: return .declined
        default: return .notResponded
        }
    }
}
