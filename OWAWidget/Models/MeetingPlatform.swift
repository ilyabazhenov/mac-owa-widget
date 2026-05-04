import Foundation

enum MeetingPlatform: String, Codable, Sendable, Hashable, CaseIterable {
    case teams
    case zoom
    case webex
    case googleMeet
    case ktalk
    case generic

    var displayName: String {
        switch self {
        case .teams:      "Teams"
        case .zoom:       "Zoom"
        case .webex:      "Webex"
        case .googleMeet: "Google Meet"
        case .ktalk:      "KTalk"
        case .generic:    "Meeting"
        }
    }

    var systemIcon: String {
        switch self {
        case .teams:      "video.fill"
        case .zoom:       "video.circle.fill"
        case .webex:      "video.badge.plus"
        case .googleMeet: "video.bubble.left.fill"
        case .ktalk:      "video.square.fill"
        case .generic:    "video"
        }
    }

    var accentColorHex: String {
        switch self {
        case .teams:      "#6264A7"
        case .zoom:       "#2D8CFF"
        case .webex:      "#00BEF3"
        case .googleMeet: "#00897B"
        case .ktalk:      "#FF6B35"
        case .generic:    "#5F6368"
        }
    }
}
