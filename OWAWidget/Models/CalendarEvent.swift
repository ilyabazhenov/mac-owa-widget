import Foundation

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
        instanceKey: String? = nil
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
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, startDate, endDate, location, bodyPreview, joinURL, platform
        case isAllDay, organizer, attendees, accountID
        case isCancelled, isOrganizer, categories, responseType, changeKey, instanceKey
    }

    func withResponseType(_ type: MeetingResponseType) -> CalendarEvent {
        CalendarEvent(
            id: id, title: title, startDate: startDate, endDate: endDate,
            location: location, bodyPreview: bodyPreview, joinURL: joinURL,
            platform: platform, isAllDay: isAllDay, organizer: organizer,
            attendees: attendees, accountID: accountID,
            isCancelled: isCancelled, isOrganizer: isOrganizer,
            categories: categories, responseType: type, changeKey: changeKey,
            instanceKey: instanceKey
        )
    }

    var isHappeningNow: Bool {
        let now = Date()
        return startDate <= now && endDate > now
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
