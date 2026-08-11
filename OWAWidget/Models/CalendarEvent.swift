import Foundation

/// Whether an attendee was invited as a required or an optional participant.
/// (Named distinctly from `AttendeeKind` in MeetingCreationModels, which models compose-time input.)
enum EventAttendeeKind: String, Codable, Sendable, Hashable {
    case required, optional
}

/// A single meeting participant with their RSVP status. Loaded lazily via `GetItem`
/// because `GetCalendarView` (the sync request) does not return attendee collections.
struct EventAttendee: Identifiable, Sendable, Hashable, Codable {
    let name: String
    let email: String?
    let kind: EventAttendeeKind
    let response: MeetingResponseType

    /// Stable identity for `ForEach`: email is unique when present, otherwise fall back to name+kind.
    var id: String { (email?.isEmpty == false ? email! : name) + "|" + kind.rawValue }
}

/// Everything the detail panel loads lazily for one meeting. `GetCalendarView` returns neither
/// attendees nor the full body (only a 255-character `Preview`), so both come from a single
/// `GetCalendarEvent` request.
struct CalendarEventDetails: Sendable, Hashable {
    let attendees: [EventAttendee]
    /// Full agenda text; `nil` when the meeting has no body or the server returned none.
    let body: String?
    /// Original markup, kept so the panel can rebuild real tables. Never persisted — it is an
    /// order of magnitude larger than the text and is refetched on demand anyway.
    let bodyHTML: String?

    init(attendees: [EventAttendee], body: String? = nil, bodyHTML: String? = nil) {
        self.attendees = attendees
        self.body = body
        self.bodyHTML = bodyHTML
    }
}

struct CalendarEvent: Identifiable, Sendable, Hashable, Codable {
    let id: String
    let title: String
    let startDate: Date
    let endDate: Date
    let location: String?
    let bodyPreview: String?
    let joinURL: URL?
    let platform: MeetingPlatform
    let isAllDay: Bool
    let organizer: String?
    let attendees: [String]
    let accountID: UUID
    let isCancelled: Bool
    let isOrganizer: Bool
    let categories: [String]
    let responseType: MeetingResponseType
    let changeKey: String?
    let instanceKey: String?
    /// Lazily loaded participant list. `nil` = not yet fetched; `[]` = fetched, no attendees.
    let detailedAttendees: [EventAttendee]?
    /// Lazily loaded full agenda. `bodyPreview` from the sync request is capped at 255 characters
    /// by Exchange, so this is the only place the complete text ever lives.
    let fullBody: String?
    /// Markup behind `fullBody`, used to render tables. In-memory only: it is not part of the
    /// Codable representation, so the on-disk cache stays small.
    let fullBodyHTML: String?

    init(
        id: String,
        title: String,
        startDate: Date,
        endDate: Date,
        location: String?,
        bodyPreview: String?,
        joinURL: URL?,
        platform: MeetingPlatform,
        isAllDay: Bool,
        organizer: String?,
        attendees: [String] = [],
        accountID: UUID,
        isCancelled: Bool = false,
        isOrganizer: Bool = false,
        categories: [String] = [],
        responseType: MeetingResponseType = .notResponded,
        changeKey: String? = nil,
        instanceKey: String? = nil,
        detailedAttendees: [EventAttendee]? = nil,
        fullBody: String? = nil,
        fullBodyHTML: String? = nil
    ) {
        self.id = id
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.location = location
        self.bodyPreview = bodyPreview
        self.joinURL = joinURL
        self.platform = platform
        self.isAllDay = isAllDay
        self.organizer = organizer
        self.attendees = attendees
        self.accountID = accountID
        self.isCancelled = isCancelled
        self.isOrganizer = isOrganizer
        self.categories = categories
        self.responseType = responseType
        self.changeKey = changeKey
        self.instanceKey = instanceKey
        self.detailedAttendees = detailedAttendees
        self.fullBody = fullBody
        self.fullBodyHTML = fullBodyHTML
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        startDate = try c.decode(Date.self, forKey: .startDate)
        endDate = try c.decode(Date.self, forKey: .endDate)
        location = try c.decodeIfPresent(String.self, forKey: .location)
        bodyPreview = try c.decodeIfPresent(String.self, forKey: .bodyPreview)
        joinURL = try c.decodeIfPresent(URL.self, forKey: .joinURL)
        platform = try c.decode(MeetingPlatform.self, forKey: .platform)
        isAllDay = try c.decode(Bool.self, forKey: .isAllDay)
        organizer = try c.decodeIfPresent(String.self, forKey: .organizer)
        attendees = try c.decodeIfPresent([String].self, forKey: .attendees) ?? []
        accountID = try c.decode(UUID.self, forKey: .accountID)
        isCancelled = try c.decodeIfPresent(Bool.self, forKey: .isCancelled) ?? false
        isOrganizer = try c.decodeIfPresent(Bool.self, forKey: .isOrganizer) ?? false
        categories = try c.decodeIfPresent([String].self, forKey: .categories) ?? []
        responseType = try c.decodeIfPresent(MeetingResponseType.self, forKey: .responseType) ?? .notResponded
        changeKey = try c.decodeIfPresent(String.self, forKey: .changeKey)
        instanceKey = try c.decodeIfPresent(String.self, forKey: .instanceKey)
        detailedAttendees = try c.decodeIfPresent([EventAttendee].self, forKey: .detailedAttendees)
        fullBody = try c.decodeIfPresent(String.self, forKey: .fullBody)
        fullBodyHTML = nil
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(startDate, forKey: .startDate)
        try c.encode(endDate, forKey: .endDate)
        try c.encodeIfPresent(location, forKey: .location)
        try c.encodeIfPresent(bodyPreview, forKey: .bodyPreview)
        try c.encodeIfPresent(joinURL, forKey: .joinURL)
        try c.encode(platform, forKey: .platform)
        try c.encode(isAllDay, forKey: .isAllDay)
        try c.encodeIfPresent(organizer, forKey: .organizer)
        try c.encode(attendees, forKey: .attendees)
        try c.encode(accountID, forKey: .accountID)
        try c.encode(isCancelled, forKey: .isCancelled)
        try c.encode(isOrganizer, forKey: .isOrganizer)
        try c.encode(categories, forKey: .categories)
        try c.encode(responseType, forKey: .responseType)
        try c.encodeIfPresent(changeKey, forKey: .changeKey)
        try c.encodeIfPresent(instanceKey, forKey: .instanceKey)
        try c.encodeIfPresent(detailedAttendees, forKey: .detailedAttendees)
        try c.encodeIfPresent(fullBody, forKey: .fullBody)
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, startDate, endDate, location, bodyPreview, joinURL, platform
        case isAllDay, organizer, attendees, accountID
        case isCancelled, isOrganizer, categories, responseType, changeKey, instanceKey
        case detailedAttendees, fullBody
    }

    func withResponseType(_ type: MeetingResponseType) -> CalendarEvent {
        CalendarEvent(
            id: id, title: title, startDate: startDate, endDate: endDate,
            location: location, bodyPreview: bodyPreview, joinURL: joinURL,
            platform: platform, isAllDay: isAllDay, organizer: organizer,
            attendees: attendees, accountID: accountID,
            isCancelled: isCancelled, isOrganizer: isOrganizer,
            categories: categories, responseType: type, changeKey: changeKey,
            instanceKey: instanceKey, detailedAttendees: detailedAttendees,
            fullBody: fullBody, fullBodyHTML: fullBodyHTML
        )
    }

    /// Caches the lazily loaded detail payload. A body that came back empty keeps whatever was
    /// cached before instead of dropping the user back to the truncated preview.
    func withDetails(_ details: CalendarEventDetails) -> CalendarEvent {
        CalendarEvent(
            id: id, title: title, startDate: startDate, endDate: endDate,
            location: location, bodyPreview: bodyPreview, joinURL: joinURL,
            platform: platform, isAllDay: isAllDay, organizer: organizer,
            attendees: attendees, accountID: accountID,
            isCancelled: isCancelled, isOrganizer: isOrganizer,
            categories: categories, responseType: responseType, changeKey: changeKey,
            instanceKey: instanceKey, detailedAttendees: details.attendees,
            fullBody: details.body ?? fullBody,
            fullBodyHTML: details.bodyHTML ?? fullBodyHTML
        )
    }

    /// Text to show as the description: the full body once loaded, the truncated preview until then.
    var displayBody: String? {
        let text = (fullBody ?? bodyPreview)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (text?.isEmpty == false) ? text : nil
    }

    var isHappeningNow: Bool {
        let now = Date()
        return startDate <= now && endDate > now
    }

    /// Past for today only: ended meetings are dimmed on the timeline; other days are unchanged.
    var isPast: Bool {
        endDate < Date() && AppTimeZone.calendar.isDateInToday(startDate)
    }

    var minutesUntilStart: Int {
        max(0, Int(startDate.timeIntervalSinceNow / 60))
    }

    var duration: TimeInterval {
        endDate.timeIntervalSince(startDate)
    }

    var hasJoinURL: Bool { joinURL != nil }

    /// Effective cancellation handles both explicit flag and subject prefixes from legacy/cached payloads.
    var isEffectivelyCancelled: Bool {
        if isCancelled { return true }
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.hasPrefix("отменено:") || normalized.hasPrefix("cancelled:") || normalized.hasPrefix("canceled:")
    }

    /// URL used for Join/Copy actions; cancelled meetings hide actions even if a URL remains cached.
    var joinURLForActions: URL? {
        guard !isEffectivelyCancelled else { return nil }
        return joinURL
    }
}
