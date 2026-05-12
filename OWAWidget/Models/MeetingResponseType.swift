import Foundation

enum MeetingResponseType: String, Codable, Sendable, Hashable {
    case notResponded, accepted, tentative, declined, organizer
}

enum MeetingResponseAction: Sendable {
    case accept, tentative, decline
}
