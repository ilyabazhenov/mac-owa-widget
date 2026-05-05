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
    let Body: OWABodyContent?
    let UniqueBody: OWABodyContent?
    let NormalizedBody: OWABodyContent?
    let Preview: String?
    let JoinOnlineMeetingUrl: String?
    let RequiredAttendees: OWAAttendeeList?
    let OptionalAttendees: OWAAttendeeList?
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

    init(Value: String?) {
        self.Value = Value
    }

    init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: CodingKeys.self) {
            Value = try container.decodeIfPresent(String.self, forKey: .Value)
            return
        }

        if let single = try? decoder.singleValueContainer(),
           let raw = try? single.decode(String.self) {
            Value = raw
            return
        }

        Value = nil
    }

    private enum CodingKeys: String, CodingKey {
        case Value
    }
}

struct OWABodyContent: Decodable {
    let Value: String?
    let BodyType: String?

    init(Value: String?, BodyType: String? = nil) {
        self.Value = Value
        self.BodyType = BodyType
    }

    init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: CodingKeys.self) {
            Value = try container.decodeIfPresent(String.self, forKey: .Value)
            BodyType = try container.decodeIfPresent(String.self, forKey: .BodyType)
            return
        }

        if let single = try? decoder.singleValueContainer(),
           let raw = try? single.decode(String.self) {
            Value = raw
            BodyType = nil
            return
        }

        Value = nil
        BodyType = nil
    }

    private enum CodingKeys: String, CodingKey {
        case Value
        case BodyType
    }
}

// OWA sometimes serializes a single attendee as an object, multiple as an array.
struct OWAAttendeeList: Decodable {
    let attendees: [OWAAttendee]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let arr = try? container.decode([OWAAttendee].self, forKey: .Attendee) {
            attendees = arr
        } else if let single = try? container.decode(OWAAttendee.self, forKey: .Attendee) {
            attendees = [single]
        } else {
            attendees = []
        }
    }

    enum CodingKeys: String, CodingKey { case Attendee }
}

struct OWAAttendee: Decodable {
    let Mailbox: OWAMailbox?
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
