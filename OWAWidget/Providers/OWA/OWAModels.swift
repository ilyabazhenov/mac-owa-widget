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
    let IsCancelled: Bool?
    let IsOrganizer: Bool?
    let Categories: [String]?
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

    init(
        ItemId: OWAItemId?,
        Subject: String?,
        Start: String?,
        End: String?,
        IsAllDayEvent: Bool?,
        Location: OWALocation?,
        Organizer: OWAOrganizer?,
        TextBody: OWATextBody?,
        Body: OWABodyContent?,
        UniqueBody: OWABodyContent?,
        NormalizedBody: OWABodyContent?,
        Preview: String?,
        JoinOnlineMeetingUrl: String?,
        RequiredAttendees: OWAAttendeeList?,
        OptionalAttendees: OWAAttendeeList?,
        IsCancelled: Bool? = nil,
        IsOrganizer: Bool? = nil,
        Categories: [String]? = nil
    ) {
        self.ItemId = ItemId
        self.Subject = Subject
        self.Start = Start
        self.End = End
        self.IsAllDayEvent = IsAllDayEvent
        self.IsCancelled = IsCancelled
        self.IsOrganizer = IsOrganizer
        self.Categories = Categories
        self.Location = Location
        self.Organizer = Organizer
        self.TextBody = TextBody
        self.Body = Body
        self.UniqueBody = UniqueBody
        self.NormalizedBody = NormalizedBody
        self.Preview = Preview
        self.JoinOnlineMeetingUrl = JoinOnlineMeetingUrl
        self.RequiredAttendees = RequiredAttendees
        self.OptionalAttendees = OptionalAttendees
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ItemId = try c.decodeIfPresent(OWAItemId.self, forKey: .ItemId)
        Subject = try c.decodeIfPresent(String.self, forKey: .Subject)
        Start = try c.decodeIfPresent(String.self, forKey: .Start)
        End = try c.decodeIfPresent(String.self, forKey: .End)
        IsAllDayEvent = try c.decodeIfPresent(Bool.self, forKey: .IsAllDayEvent)
        IsCancelled = try c.decodeIfPresent(Bool.self, forKey: .IsCancelled)
        IsOrganizer = try c.decodeIfPresent(Bool.self, forKey: .IsOrganizer)
        Categories = Self.decodeCategories(from: c)
        Location = try c.decodeIfPresent(OWALocation.self, forKey: .Location)
        Organizer = try c.decodeIfPresent(OWAOrganizer.self, forKey: .Organizer)
        TextBody = try c.decodeIfPresent(OWATextBody.self, forKey: .TextBody)
        Body = try c.decodeIfPresent(OWABodyContent.self, forKey: .Body)
        UniqueBody = try c.decodeIfPresent(OWABodyContent.self, forKey: .UniqueBody)
        NormalizedBody = try c.decodeIfPresent(OWABodyContent.self, forKey: .NormalizedBody)
        Preview = try c.decodeIfPresent(String.self, forKey: .Preview)
        JoinOnlineMeetingUrl = try c.decodeIfPresent(String.self, forKey: .JoinOnlineMeetingUrl)
        RequiredAttendees = try c.decodeIfPresent(OWAAttendeeList.self, forKey: .RequiredAttendees)
        OptionalAttendees = try c.decodeIfPresent(OWAAttendeeList.self, forKey: .OptionalAttendees)
    }

    private enum CodingKeys: String, CodingKey {
        case ItemId, Subject, Start, End, IsAllDayEvent, IsCancelled, IsOrganizer, Categories
        case Location, Organizer, TextBody, Body, UniqueBody, NormalizedBody, Preview
        case JoinOnlineMeetingUrl, RequiredAttendees, OptionalAttendees
    }

    private struct OWAEncodedCategory: Decodable {
        let value: String?

        init(from decoder: Decoder) throws {
            if let single = try? decoder.singleValueContainer(),
               let text = try? single.decode(String.self) {
                value = text
                return
            }

            if let keyed = try? decoder.container(keyedBy: DynamicCodingKey.self) {
                let candidateKeys = [
                    "Name", "DisplayName", "Value", "CategoryName",
                    "name", "displayName", "value", "categoryName",
                    "Id", "id", "Color", "color",
                ]
                for key in candidateKeys {
                    guard let codingKey = DynamicCodingKey(stringValue: key) else { continue }
                    if let text = try? keyed.decode(String.self, forKey: codingKey), !text.isEmpty {
                        value = text
                        return
                    }
                }
            }

            value = nil
        }
    }

    private struct DynamicCodingKey: CodingKey {
        var stringValue: String
        var intValue: Int?

        init?(stringValue: String) {
            self.stringValue = stringValue
            self.intValue = nil
        }

        init?(intValue: Int) {
            self.stringValue = "\(intValue)"
            self.intValue = intValue
        }
    }

    private static func decodeCategories(from container: KeyedDecodingContainer<CodingKeys>) -> [String]? {
        if let arr = try? container.decode([String].self, forKey: .Categories) {
            return arr
        }
        if let single = try? container.decode(String.self, forKey: .Categories) {
            return [single]
        }
        if let objects = try? container.decode([OWAEncodedCategory].self, forKey: .Categories) {
            let values = objects
                .compactMap(\.value)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return values.isEmpty ? nil : values
        }
        return nil
    }
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
