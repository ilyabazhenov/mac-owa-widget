import Foundation

// MARK: - Response models

struct OWAServiceResponse: Decodable {
    let Body: OWAResponseBody?
}

struct OWAResponseBody: Decodable {
    let Items: [OWACalendarItem]?
}

struct OWACalendarItem: Decodable {
    let ItemId: OWAItemId?
    let Subject: String?
    let Start: String?
    let End: String?
    let IsAllDayEvent: Bool?
    let Location: OWALocation?
    let Organizer: OWAOrganizer?
    let TextBody: OWATextBody?
    let JoinOnlineMeetingUrl: String?
}

struct OWAItemId: Decodable {
    let Id: String
    let ChangeKey: String?
}

struct OWALocation: Decodable {
    let DisplayName: String?
}

struct OWAOrganizer: Decodable {
    let Mailbox: OWAMailbox?
}

struct OWAMailbox: Decodable {
    let Name: String?
    let EmailAddress: String?
}

struct OWATextBody: Decodable {
    let Value: String?
}

// MARK: - Errors

enum OWAError: LocalizedError {
    case invalidURL(String)
    case authenticationFailed(String)
    case notAuthenticated
    case invalidResponse
    case httpError(Int, String)
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .invalidURL(let u):           "Invalid server URL: \(u)"
        case .authenticationFailed(let m): "Authentication failed: \(m)"
        case .notAuthenticated:            "Not authenticated"
        case .invalidResponse:             "Invalid server response"
        case .httpError(let c, let m):     "HTTP \(c): \(m)"
        case .encodingFailed:              "Failed to encode request"
        }
    }
}
