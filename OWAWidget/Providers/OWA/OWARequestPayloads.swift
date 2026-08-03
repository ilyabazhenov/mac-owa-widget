import Foundation

enum OWACalendarViewRequestPayload {
    static func make(
        start: Date,
        end: Date,
        timezoneID: String,
        folderIdentifier: OWAFolderIdentifier?
    ) -> [String: Any] {
        let localFmt = localDateFormatter()
        return [
            "__type": "GetCalendarViewJsonRequest:#Exchange",
            "Header": commonHeader(timezoneID: timezoneID),
            "Body": [
                "__type": "GetCalendarViewRequest:#Exchange",
                "CalendarId": calendarID(folderIdentifier: folderIdentifier),
                "RangeStart": localFmt.string(from: start),
                "RangeEnd": localFmt.string(from: end),
            ] as [String: Any],
        ]
    }

    private static func calendarID(folderIdentifier: OWAFolderIdentifier?) -> [String: Any] {
        if let folderIdentifier {
            var folder: [String: Any] = [
                "__type": "FolderId:#Exchange",
                "Id": folderIdentifier.id,
            ]
            if let changeKey = folderIdentifier.changeKey {
                folder["ChangeKey"] = changeKey
            }
            return [
                "__type": "TargetFolderId:#Exchange",
                "BaseFolderId": folder,
            ]
        }

        return [
            "__type": "TargetFolderId:#Exchange",
            "BaseFolderId": [
                "__type": "DistinguishedFolderId:#Exchange",
                "Id": "calendar",
            ] as [String: Any],
        ]
    }

    private static func commonHeader(timezoneID: String) -> [String: Any] {
        [
            "__type": "JsonRequestHeaders:#Exchange",
            "RequestServerVersion": "V2017_08_18",
            "TimeZoneContext": [
                "__type": "TimeZoneContext:#Exchange",
                "TimeZoneDefinition": [
                    "__type": "TimeZoneDefinitionType:#Exchange",
                    "Id": timezoneID,
                ] as [String: Any],
            ] as [String: Any],
        ]
    }

    private static func localDateFormatter() -> DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        return f
    }
}

// MARK: - GetCalendarEvent (attendees)

enum OWAGetCalendarEventPayload {
    /// Mirrors the OWA web client's calendar peek request (`action=GetCalendarEvent`). `GetCalendarView`
    /// (the sync request) does not return attendee collections; `GetCalendarEvent` returns the full
    /// event — including `RequiredAttendees`/`OptionalAttendees` — for a single event id.
    /// Shape captured from a live corporate OWA HAR (Exchange 15.2.1748.10).
    static func make(itemId: String, changeKey: String?, timezoneID: String) -> [String: Any] {
        var eventId: [String: Any] = [
            "__type": "ItemId:#Exchange",
            "Id": itemId,
        ]
        if let changeKey {
            eventId["ChangeKey"] = changeKey
        }
        return [
            "__type": "GetCalendarEventJsonRequest:#Exchange",
            "Header": owaSharedHeader(timezoneID: timezoneID),
            "Body": [
                "__type": "GetCalendarEventRequest:#Exchange",
                "EventIds": [eventId],
                "ItemShape": [
                    "__type": "ItemResponseShape:#Exchange",
                    "BaseShape": "IdOnly",
                    "FilterHtmlContent": true,
                    "BlockExternalImagesIfSenderUntrusted": true,
                    "BlockContentFromUnknownSenders": false,
                    "AddBlankTargetToLinks": true,
                    "ClientSupportsIrm": true,
                    "FilterInlineSafetyTips": true,
                    "MaximumBodySize": 0,
                    "BodyType": "HTML",
                ] as [String: Any],
            ] as [String: Any],
        ]
    }
}

// MARK: - Shared helpers

private func owaSharedHeader(timezoneID: String, version: String = "V2017_08_18") -> [String: Any] {
    [
        "__type": "JsonRequestHeaders:#Exchange",
        "RequestServerVersion": version,
        "TimeZoneContext": [
            "__type": "TimeZoneContext:#Exchange",
            "TimeZoneDefinition": [
                "__type": "TimeZoneDefinitionType:#Exchange",
                "Id": timezoneID,
            ] as [String: Any],
        ] as [String: Any],
    ]
}

private func owaLocalDateFormatter() -> DateFormatter {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone.current
    return f
}

// MARK: - FindPeople

enum OWAFindPeoplePayload {
    /// Calendar compose attendee search from browser HAR (`tmp/owa-debug/FinePeopleRequestHARExample.txt`).
    /// **No `ParentFolderId`** — differs from GAL-bulk scripts; includes `AggregationRestriction`, `Context`, and
    /// `PersonaShape.AdditionalProperties`. Requires URL `…FindPeople&ID=-199&AC=1` and headers `X-OWA-ActionId` / `X-OWA-ActionName`.
    static func makeComposeCalendarHAR(query: String, timezoneID: String) -> [String: Any] {
        let aggregationRestriction: [String: Any] = [
            "__type": "RestrictionType:#Exchange",
            "Item": [
                "__type": "Or:#Exchange",
                "Items": [
                    [
                        "__type": "Exists:#Exchange",
                        "Item": [
                            "__type": "PropertyUri:#Exchange",
                            "FieldURI": "PersonaEmailAddress",
                        ] as [String: Any],
                    ],
                    [
                        "__type": "IsEqualTo:#Exchange",
                        "Item": [
                            "__type": "PropertyUri:#Exchange",
                            "FieldURI": "PersonaType",
                        ] as [String: Any],
                        "FieldURIOrConstant": [
                            "__type": "FieldURIOrConstantType:#Exchange",
                            "Item": [
                                "__type": "Constant:#Exchange",
                                "Value": "DistributionList",
                            ] as [String: Any],
                        ] as [String: Any],
                    ],
                ] as [Any],
            ] as [String: Any],
        ]
        let context: [[String: Any]] = [
            ["__type": "ContextProperty:#Exchange", "Key": "AppName", "Value": "OWA"],
            ["__type": "ContextProperty:#Exchange", "Key": "AppScenario", "Value": "Calendar"],
            ["__type": "ContextProperty:#Exchange", "Key": "ClientSessionId", "Value": ""],
        ]
        return [
            "__type": "FindPeopleJsonRequest:#Exchange",
            "Header": owaSharedHeader(timezoneID: timezoneID, version: "Exchange2013"),
            "Body": [
                "__type": "FindPeopleRequest:#Exchange",
                "IndexedPageItemView": [
                    "__type": "IndexedPageView:#Exchange",
                    "BasePoint": "Beginning",
                    "Offset": 0,
                ] as [String: Any],
                "QueryString": query,
                "AggregationRestriction": aggregationRestriction,
                "PersonaShape": [
                    "__type": "PersonaResponseShape:#Exchange",
                    "BaseShape": "Default",
                    "AdditionalProperties": [
                        ["__type": "PropertyUri:#Exchange", "FieldURI": "PersonaAttributions"],
                        ["__type": "PropertyUri:#Exchange", "FieldURI": "PersonaCompanyName"],
                    ],
                ] as [String: Any],
                "ShouldResolveOneOffEmailAddress": true,
                "SearchPeopleSuggestionIndex": false,
                "Context": context,
            ] as [String: Any],
        ]
    }
}

// MARK: - GetUserAvailabilityInternal

enum OWAUserAvailabilityPayload {
    static func make(emails: [String], start: Date, end: Date, timezoneID: String) -> [String: Any] {
        let fmt = owaLocalDateFormatter()
        let mailboxes: [[String: Any]] = emails.map { email in
            [
                "__type": "MailboxData:#Exchange",
                "Email": [
                    "__type": "EmailAddress:#Exchange",
                    "Address": email,
                ] as [String: Any],
            ]
        }
        return [
            "request": [
                "__type": "GetUserAvailabilityInternalJsonRequest:#Exchange",
                "Header": owaSharedHeader(timezoneID: timezoneID, version: "Exchange2013"),
                "Body": [
                    "__type": "GetUserAvailabilityRequest:#Exchange",
                    "MailboxDataArray": mailboxes,
                    "FreeBusyViewOptions": [
                        "__type": "FreeBusyViewOptions:#Exchange",
                        "MergedFreeBusyIntervalInMinutes": 30,
                        "RequestedView": "DetailedMerged",
                        "TimeWindow": [
                            "__type": "Duration:#Exchange",
                            "StartTime": fmt.string(from: start),
                            "EndTime": fmt.string(from: end),
                        ] as [String: Any],
                    ] as [String: Any],
                ] as [String: Any],
            ] as [String: Any],
        ]
    }
}

// MARK: - CreateCalendarEvent

enum OWACreateCalendarEventPayload {
    /// HTML for calendar item body; plain-text lines become `<br/>`-separated escaped text.
    static func calendarBodyHTML(plainAgenda: String) -> String {
        let sanitized = plainAgenda.replacingOccurrences(of: "]]>", with: "]] >")
        let trimmed = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return emptyHTMLBody() }
        let inner = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
            .map { escapePlainForHTMLFragment(String($0)) }
            .joined(separator: "<br/>")
        return "<html><head><meta http-equiv=\"Content-Type\" content=\"text/html; charset=UTF-8\">" +
            "</head><body dir=\"ltr\"><div>\(inner)</div></body></html>"
    }

    private static func escapePlainForHTMLFragment(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func emptyHTMLBody() -> String {
        "<html><head><meta http-equiv=\"Content-Type\" content=\"text/html; charset=UTF-8\">" +
        "</head><body dir=\"ltr\"><div><br></div></body></html>"
    }

    /// Стандартный EWS-форматтер для дат в UTC: `yyyy-MM-dd'T'HH:mm:ss'Z'`.
    static func ewsDateFormatter() -> DateFormatter {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return fmt
    }

    /// Чистый XML-эскейп для значений в EWS SOAP-payload.
    static func escapeXML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Собирает SOAP-envelope для EWS `CreateItem` (приглашение на встречу).
    ///
    /// Чистая функция — без сети и без actor-зависимостей, чтобы покрывать
    /// тестами экранирование XML, порядок Required → Optional и защиту CDATA.
    static func createItemSOAP(
        title: String,
        agenda: String,
        location: String,
        start: Date,
        end: Date,
        requiredAttendees: [ResolvedAttendee],
        optionalAttendees: [ResolvedAttendee] = [],
        dateFormatter: DateFormatter? = nil
    ) -> String {
        let fmt = dateFormatter ?? ewsDateFormatter()

        func attendeesXML(_ list: [ResolvedAttendee]) -> String {
            list.map { a in
                "<t:Attendee><t:Mailbox><t:EmailAddress>\(escapeXML(a.email))</t:EmailAddress></t:Mailbox></t:Attendee>"
            }.joined()
        }

        // EWS schema order: RequiredAttendees must precede OptionalAttendees in CalendarItem.
        // Пустой `<t:RequiredAttendees/>` Exchange отвергает на схеме — поэтому при отсутствии
        // участников опускаем элемент полностью и превращаем CreateItem в обычный appointment.
        let requiredXML = requiredAttendees.isEmpty
            ? ""
            : "<t:RequiredAttendees>\(attendeesXML(requiredAttendees))</t:RequiredAttendees>"
        let optionalXML = optionalAttendees.isEmpty
            ? ""
            : "<t:OptionalAttendees>\(attendeesXML(optionalAttendees))</t:OptionalAttendees>"

        // SendToNone превращает запрос в self-only appointment без рассылки приглашений;
        // если есть хотя бы один участник — копируем приглашение всем и сохраняем в календарь.
        let sendDisposition = requiredAttendees.isEmpty && optionalAttendees.isEmpty
            ? "SendToNone"
            : "SendToAllAndSaveCopy"

        let agendaTrimmed = agenda.trimmingCharacters(in: .whitespacesAndNewlines)
        let bodyXML: String
        if agendaTrimmed.isEmpty {
            bodyXML = ""
        } else {
            let html = calendarBodyHTML(plainAgenda: agenda)
            bodyXML = "<t:Body BodyType=\"HTML\"><![CDATA[\(html)]]></t:Body>"
        }

        let trimmedLocation = location.trimmingCharacters(in: .whitespacesAndNewlines)
        let locationXML = trimmedLocation.isEmpty
            ? ""
            : "<t:Location>\(escapeXML(trimmedLocation))</t:Location>"

        return """
        <?xml version="1.0" encoding="utf-8"?>
        <soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/" \
        xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types" \
        xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages">
          <soap:Header>
            <t:RequestServerVersion Version="Exchange2013_SP1"/>
            <t:TimeZoneContext><t:TimeZoneDefinition Id="UTC"/></t:TimeZoneContext>
          </soap:Header>
          <soap:Body>
            <m:CreateItem SendMeetingInvitations="\(sendDisposition)">
              <m:SavedItemFolderId><t:DistinguishedFolderId Id="calendar"/></m:SavedItemFolderId>
              <m:Items>
                <t:CalendarItem>
                  <t:Subject>\(escapeXML(title))</t:Subject>
                  \(bodyXML)
                  \(locationXML)
                  <t:Start>\(fmt.string(from: start))</t:Start>
                  <t:End>\(fmt.string(from: end))</t:End>
                  <t:IsReminderSet>true</t:IsReminderSet>
                  <t:ReminderMinutesBeforeStart>15</t:ReminderMinutesBeforeStart>
                  \(requiredXML)
                  \(optionalXML)
                </t:CalendarItem>
              </m:Items>
            </m:CreateItem>
          </soap:Body>
        </soap:Envelope>
        """
    }
}

// MARK: - GetCalendarEvent attendees parser

/// Tolerant extractor for attendees out of a `GetCalendarEvent` response. The exact wrapper shape
/// varies by Exchange build, so we recursively locate `RequiredAttendees`/`OptionalAttendees`
/// wherever they sit and accept the several shapes OWA uses for the attendee list.
enum OWACalendarEventAttendeesParser {
    static func attendees(fromJSONData data: Data) -> [EventAttendee] {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var result: [EventAttendee] = []
        collect(in: json, into: &result)
        return result
    }

    private static func collect(in value: Any, into result: inout [EventAttendee]) {
        if let array = value as? [Any] {
            for element in array { collect(in: element, into: &result) }
            return
        }
        guard let dict = value as? [String: Any] else { return }

        if let required = dict["RequiredAttendees"] {
            result.append(contentsOf: parseContainer(required, kind: .required))
        }
        if let optional = dict["OptionalAttendees"] {
            result.append(contentsOf: parseContainer(optional, kind: .optional))
        }
        for (key, nested) in dict where key != "RequiredAttendees" && key != "OptionalAttendees" {
            collect(in: nested, into: &result)
        }
    }

    /// Accepts `{ "Attendee": [...] }`, `{ "Attendee": {...} }`, `[ {...} ]`, or a single attendee dict.
    private static func parseContainer(_ value: Any, kind: EventAttendeeKind) -> [EventAttendee] {
        if let dict = value as? [String: Any], let inner = dict["Attendee"] {
            return parseList(inner, kind: kind)
        }
        return parseList(value, kind: kind)
    }

    private static func parseList(_ value: Any, kind: EventAttendeeKind) -> [EventAttendee] {
        if let array = value as? [Any] {
            return array.compactMap { parseAttendee($0, kind: kind) }
        }
        if let single = parseAttendee(value, kind: kind) {
            return [single]
        }
        return []
    }

    private static func parseAttendee(_ value: Any, kind: EventAttendeeKind) -> EventAttendee? {
        guard let dict = value as? [String: Any] else { return nil }
        let mailbox = dict["Mailbox"] as? [String: Any]
        let name = (mailbox?["Name"] as? String ?? dict["Name"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let rawEmail = (mailbox?["EmailAddress"] as? String ?? dict["EmailAddress"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let email = (rawEmail?.isEmpty == false) ? rawEmail : nil
        let displayName = name.isEmpty ? (email ?? "") : name
        guard !displayName.isEmpty else { return nil }
        return EventAttendee(
            name: displayName,
            email: email,
            kind: kind,
            response: mapResponse(dict["ResponseType"] as? String)
        )
    }

    private static func mapResponse(_ raw: String?) -> MeetingResponseType {
        switch raw {
        case "Accept":    return .accepted
        case "Tentative": return .tentative
        case "Decline":   return .declined
        case "Organizer": return .organizer
        default:          return .notResponded
        }
    }
}

// MARK: - CalendarFolders parser

enum OWACalendarFoldersParser {
    static func defaultCalendarFolderIdentifier(from data: Data) -> OWAFolderIdentifier? {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let candidates = folderCandidates(in: json)

        return candidates.first { $0.isDefaultCalendar }?.identifier
            ?? candidates.first { $0.looksLikePrimaryCalendar }?.identifier
            ?? candidates.first?.identifier
    }

    private struct Candidate {
        let identifier: OWAFolderIdentifier
        let displayName: String?
        let distinguishedFolderID: String?
        let isDefaultFolder: Bool
        let isDefaultCalendar: Bool

        var looksLikePrimaryCalendar: Bool {
            let normalizedName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return distinguishedFolderID == "calendar" || normalizedName == "calendar" || isDefaultFolder
        }
    }

    private static func folderCandidates(in value: Any) -> [Candidate] {
        if let dictionary = value as? [String: Any] {
            var candidates: [Candidate] = []

            if let folderID = dictionary["FolderId"] as? [String: Any],
               let id = folderID["Id"] as? String,
               !id.isEmpty {
                candidates.append(
                    Candidate(
                        identifier: OWAFolderIdentifier(id: id, changeKey: folderID["ChangeKey"] as? String),
                        displayName: dictionary["DisplayName"] as? String,
                        distinguishedFolderID: dictionary["DistinguishedFolderId"] as? String,
                        isDefaultFolder: dictionary["IsDefaultFolder"] as? Bool ?? false,
                        isDefaultCalendar: dictionary["IsDefaultCalendar"] as? Bool ?? false
                    )
                )
            }

            for nested in dictionary.values {
                candidates.append(contentsOf: folderCandidates(in: nested))
            }
            return candidates
        }

        if let array = value as? [Any] {
            return array.flatMap { folderCandidates(in: $0) }
        }

        return []
    }
}
