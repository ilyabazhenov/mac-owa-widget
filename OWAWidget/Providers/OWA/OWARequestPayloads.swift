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
