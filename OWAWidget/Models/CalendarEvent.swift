import Foundation

struct CalendarEvent: Identifiable, Sendable, Hashable {
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
