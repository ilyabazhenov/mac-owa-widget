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

private func owaLocalDateFormatter(withMilliseconds: Bool = false) -> DateFormatter {
    let f = DateFormatter()
    f.dateFormat = withMilliseconds ? "yyyy-MM-dd'T'HH:mm:ss.SSS" : "yyyy-MM-dd'T'HH:mm:ss"
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone.current
    return f
}

// MARK: - FindPeople

/// Different JSON shapes for `FindPeople`; some Exchange builds return HTTP 500 / `MemberAccessException` / abstract class for one variant but accept another (even with the same GAL `AddressListId`).
enum FindPeoplePayloadVariant: Int, CaseIterable {
    /// Public GAL tooling style: `Exchange2013` + `PersonaShape` + `ShouldResolveOneOffEmailAddress` true.
    case exchange2013WithPersonaResolveSMTP = 0
    /// Same as calendar reads on the tenant (`GetCalendarView` uses `V2017_08_18`).
    case v2017WithPersonaResolveSMTP = 1
    /// Drops `PersonaShape` (some servers fail deserializing `PersonaResponseShape` for directory search).
    case exchange2013NoPersonaShape = 2
    /// OWA GAL dump script style: `V2017_08_18`, no `PersonaShape`, `ShouldResolveOneOffEmailAddress` false.
    case v2017NoPersonaResolveOff = 3
    /// OWA compose HAR style: keep `PersonaShape` but set `SearchPeopleSuggestionIndex` explicitly to false.
    case v2017WithPersonaSuggestionIndexFalse = 4
    /// Some tenants return a generic `FolderId` from filters; deserializer expects `FolderId` instead of `AddressListId` in `ParentFolderId`.
    case v2017WithPersonaParentAsFolderId = 5
}

enum OWAFindPeoplePayload {
    /// `ParentFolderId` / `AddressListId` (from `GetPeopleFilters`) is required on many servers. Pick `variant` via `FindPeoplePayloadVariant` until OWA returns HTTP 2xx.
    static func make(
        query: String,
        timezoneID: String,
        globalAddressListFolderId: String,
        variant: FindPeoplePayloadVariant
    ) -> [String: Any] {
        let headerVersion: String
        let includePersonaShape: Bool
        let resolveOneOff: Bool
        let maxEntriesReturned: Int?
        let searchPeopleSuggestionIndexFalse: Bool
        let parentBaseFolderUsesFolderIdType: Bool
        switch variant {
        case .exchange2013WithPersonaResolveSMTP:
            headerVersion = "Exchange2013"
            includePersonaShape = true
            resolveOneOff = true
            maxEntriesReturned = 50
            searchPeopleSuggestionIndexFalse = false
            parentBaseFolderUsesFolderIdType = false
        case .v2017WithPersonaResolveSMTP:
            headerVersion = "V2017_08_18"
            includePersonaShape = true
            resolveOneOff = true
            maxEntriesReturned = 50
            searchPeopleSuggestionIndexFalse = false
            parentBaseFolderUsesFolderIdType = false
        case .exchange2013NoPersonaShape:
            headerVersion = "Exchange2013"
            includePersonaShape = false
            resolveOneOff = true
            maxEntriesReturned = 50
            searchPeopleSuggestionIndexFalse = false
            parentBaseFolderUsesFolderIdType = false
        case .v2017NoPersonaResolveOff:
            headerVersion = "V2017_08_18"
            includePersonaShape = false
            resolveOneOff = false
            maxEntriesReturned = 100
            searchPeopleSuggestionIndexFalse = false
            parentBaseFolderUsesFolderIdType = false
        case .v2017WithPersonaSuggestionIndexFalse:
            headerVersion = "V2017_08_18"
            includePersonaShape = true
            resolveOneOff = true
            maxEntriesReturned = 50
            searchPeopleSuggestionIndexFalse = true
            parentBaseFolderUsesFolderIdType = false
        case .v2017WithPersonaParentAsFolderId:
            headerVersion = "V2017_08_18"
            includePersonaShape = true
            resolveOneOff = true
            maxEntriesReturned = 50
            searchPeopleSuggestionIndexFalse = false
            parentBaseFolderUsesFolderIdType = true
        }

        var indexedPage: [String: Any] = [
            "__type": "IndexedPageView:#Exchange",
            "BasePoint": "Beginning",
            "Offset": 0,
        ]
        if let maxEntriesReturned {
            indexedPage["MaxEntriesReturned"] = maxEntriesReturned
        }

        let baseFolderType = parentBaseFolderUsesFolderIdType ? "FolderId:#Exchange" : "AddressListId:#Exchange"
        let parentFolder: [String: Any] = [
            "__type": "TargetFolderId:#Exchange",
            "BaseFolderId": [
                "__type": baseFolderType,
                "Id": globalAddressListFolderId,
            ] as [String: Any],
        ]

        var body: [String: Any] = [
            "__type": "FindPeopleRequest:#Exchange",
            "IndexedPageItemView": indexedPage,
            "QueryString": query,
            "ParentFolderId": parentFolder,
        ]
        if includePersonaShape {
            body["PersonaShape"] = [
                "__type": "PersonaResponseShape:#Exchange",
                "BaseShape": "Default",
            ] as [String: Any]
        }
        body["ShouldResolveOneOffEmailAddress"] = resolveOneOff
        if searchPeopleSuggestionIndexFalse {
            body["SearchPeopleSuggestionIndex"] = false
        }

        return [
            "__type": "FindPeopleJsonRequest:#Exchange",
            "Header": owaSharedHeader(timezoneID: timezoneID, version: headerVersion),
            "Body": body,
        ]
    }

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

    static func make(
        title: String,
        agenda: String,
        start: Date,
        end: Date,
        requiredAttendees: [ResolvedAttendee],
        optionalAttendees: [ResolvedAttendee] = [],
        timezoneID: String,
        folderIdentifier: OWAFolderIdentifier?
    ) -> [String: Any] {
        let fmt = owaLocalDateFormatter(withMilliseconds: true)
        func attendeeItems(_ list: [ResolvedAttendee]) -> [[String: Any]] {
            list.map { attendee in
                [
                    "__type": "AttendeeType:#Exchange",
                    "Mailbox": [
                        "Name": attendee.displayName,
                        "EmailAddress": attendee.email,
                        "RoutingType": "SMTP",
                        "MailboxType": "Mailbox",
                        "OriginalDisplayName": attendee.email,
                    ] as [String: Any],
                ]
            }
        }
        let requiredItems = attendeeItems(requiredAttendees)
        let optionalItems = attendeeItems(optionalAttendees)

        var calendarItem: [String: Any] = [
            "__type": "CalendarItem:#Exchange",
            "ClientSeriesId": UUID().uuidString.lowercased(),
            "Subject": title,
            "Body": [
                "__type": "BodyContentType:#Exchange",
                "BodyType": "HTML",
                "Value": Self.calendarBodyHTML(plainAgenda: agenda),
            ] as [String: Any],
            "Sensitivity": "Normal",
            "ReminderIsSet": true,
            "ReminderMinutesBeforeStart": 15,
            "IsResponseRequested": true,
            "DoNotForwardMeeting": false,
            "IsAllDayEvent": false,
            "Start": fmt.string(from: start),
            "End": fmt.string(from: end),
            "FreeBusyType": "Busy",
            "RequiredAttendees": requiredItems,
            "Location": [
                "__type": "EnhancedLocation:#Exchange",
                "Annotation": "",
                "DisplayName": "",
                "PostalAddress": [
                    "__type": "PersonaPostalAddress:#Exchange",
                    "Type": "Business",
                    "LocationSource": "None",
                ] as [String: Any],
            ] as [String: Any],
            "unfoldedIndex": 0,
        ]
        if !optionalItems.isEmpty {
            calendarItem["OptionalAttendees"] = optionalItems
        }

        let savedFolderID: [String: Any]
        if let folderIdentifier {
            var folder: [String: Any] = ["__type": "FolderId:#Exchange", "Id": folderIdentifier.id]
            if let changeKey = folderIdentifier.changeKey { folder["ChangeKey"] = changeKey }
            savedFolderID = ["__type": "TargetFolderId:#Exchange", "BaseFolderId": folder]
        } else {
            savedFolderID = [
                "__type": "TargetFolderId:#Exchange",
                "BaseFolderId": ["__type": "DistinguishedFolderId:#Exchange", "Id": "calendar"] as [String: Any],
            ]
        }

        return [
            "__type": "CreateItemJsonRequest:#Exchange",
            "Header": owaSharedHeader(timezoneID: timezoneID),
            "Body": [
                "__type": "CreateItemRequest:#Exchange",
                "Items": [calendarItem],
                "ClientSupportsIrm": true,
                "SavedItemFolderId": savedFolderID,
            ] as [String: Any],
        ]
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
