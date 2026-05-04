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

struct OWAFolderIdentifier: Sendable, Equatable {
    let id: String
    let changeKey: String?
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
        case .httpError(let c, let m):     Self.describeHTTPError(statusCode: c, responseBody: m)
        case .encodingFailed:              "Failed to encode request"
        }
    }

    private static func describeHTTPError(statusCode: Int, responseBody: String) -> String {
        let trimmed = responseBody.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "HTTP \(statusCode)" }

        if let message = extractOWAErrorMessage(from: trimmed) {
            return "HTTP \(statusCode): \(message)"
        }

        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            return "HTTP \(statusCode): OWA service returned an error"
        }

        return "HTTP \(statusCode): \(trimmed)"
    }

    private static func extractOWAErrorMessage(from responseBody: String) -> String? {
        guard let data = responseBody.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let body = object["Body"] as? [String: Any]
        else { return nil }

        let fault = (body["FaultMessage"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let fault, !fault.isEmpty {
            return fault
        }

        let exception = (body["ExceptionName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let exception, !exception.isEmpty {
            return exception
        }

        return nil
    }

    static func diagnosticResponseKind(from responseBody: String) -> String {
        let trimmed = responseBody.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "empty" }

        if let message = extractOWAErrorMessage(from: trimmed) {
            if message.localizedCaseInsensitiveContains("cannot create an abstract class") {
                return "fault.abstractClass"
            }
            return "fault.other"
        }

        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            return "json"
        }

        if trimmed.localizedCaseInsensitiveContains("<html") {
            return "html"
        }

        return "plain"
    }

    static func isAbstractClassHTTPError(_ error: Error) -> Bool {
        guard case .httpError(let statusCode, let responseBody) = error as? OWAError else {
            return false
        }

        return statusCode == 500 && diagnosticResponseKind(from: responseBody) == "fault.abstractClass"
    }
}
