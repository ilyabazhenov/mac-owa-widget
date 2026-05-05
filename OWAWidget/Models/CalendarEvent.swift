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
        accountID: UUID
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
}
