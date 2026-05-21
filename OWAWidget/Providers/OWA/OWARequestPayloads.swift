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
