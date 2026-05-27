import Foundation

enum MeetingEngagementScope: String, Codable, CaseIterable, Identifiable, Sendable {
    case joinableOnly
    case allEvents

    var id: String { rawValue }
}

enum MeetingEngagementPeriod: Int, Codable, CaseIterable, Identifiable, Sendable {
    case today = 1
    case sevenDays = 7
    case thirtyDays = 30

    var id: Int { rawValue }

    var dayCount: Int { rawValue }
}

enum MeetingJoinSource: String, Codable, Sendable {
    case meetingRow
    case timelineBlock
    case nextBanner
    case detailPanel
    case reminderNotification
    case reminderPicker
    case inAppReminder
    case globalShortcut
}

struct MeetingEngagementSnapshot: Sendable {
    let period: MeetingEngagementPeriod
    let scope: MeetingEngagementScope
    let eligibleMeetings: Int
    let joinedViaWidget: Int
    let streakDays: Int
    let totalJoined: Int
    let nextMilestone: Int

    var conversionRate: Double {
        guard eligibleMeetings > 0 else { return 0 }
        return Double(joinedViaWidget) / Double(eligibleMeetings)
    }

    static let empty = MeetingEngagementSnapshot(
        period: .today,
        scope: .joinableOnly,
        eligibleMeetings: 0,
        joinedViaWidget: 0,
        streakDays: 0,
        totalJoined: 0,
        nextMilestone: 10
    )
}
