import Foundation

/// Parses JSON returned by OWA `service.svc?action=FindPeople` (shape varies by build; we walk the tree defensively).
enum OWAFindPeopleParser {
    private static let maxResults = 100
    private static let maxDepth = 40

    static func attendees(fromJSONData data: Data) -> [ResolvedAttendee] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var seenLowercasedEmails = Set<String>()
        var results: [ResolvedAttendee] = []
        collect(from: root, depth: 0, results: &results, seenLowercasedEmails: &seenLowercasedEmails)
        return results
    }

    private static func collect(
        from value: Any,
        depth: Int,
        results: inout [ResolvedAttendee],
        seenLowercasedEmails: inout Set<String>
    ) {
        guard depth < maxDepth, results.count < maxResults else { return }

        if let dict = value as? [String: Any] {
            if shouldSkipSubtree(dict) {
                return
            }
            if let attendee = attendeeIfPersonaLike(dict),
               seenLowercasedEmails.insert(attendee.email.lowercased()).inserted {
                results.append(attendee)
            }
            for child in dict.values {
                collect(from: child, depth: depth + 1, results: &results, seenLowercasedEmails: &seenLowercasedEmails)
            }
        } else if let array = value as? [Any] {
            for item in array {
                collect(from: item, depth: depth + 1, results: &results, seenLowercasedEmails: &seenLowercasedEmails)
            }
        }
    }

    /// Avoid treating the outbound request envelope (embedded in some traces) as hits.
    private static func shouldSkipSubtree(_ dict: [String: Any]) -> Bool {
        guard let t = dict["__type"] as? String else { return false }
        if t.contains("FindPeopleRequest") { return true }
        if t.contains("JsonRequest") && t.contains("FindPeople") { return true }
        return false
    }

    private static func attendeeIfPersonaLike(_ dict: [String: Any]) -> ResolvedAttendee? {
        guard let email = extractPrimaryEmail(dict),
              email.contains("@"),
              email.count > 3
        else { return nil }

        let displayName = extractDisplayName(dict, attributionDepth: 0)
        guard !displayName.isEmpty else { return nil }

        let jobTitle = extractJobTitle(dict, attributionDepth: 0)

        return ResolvedAttendee(displayName: displayName, email: email, jobTitle: jobTitle)
    }

    private static func extractDisplayName(_ dict: [String: Any], attributionDepth: Int) -> String {
        if let s = dict["DisplayName"] as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return t }
        }
        if let s = dict["FileAs"] as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return t }
        }
        if let mailbox = dict["Mailbox"] as? [String: Any],
           let s = mailbox["Name"] as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return t }
        }
        if let names = dict["DisplayNames"] as? [Any] {
            for item in names {
                if let eDict = item as? [String: Any] {
                    if let s = eDict["Value"] as? String {
                        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !t.isEmpty { return t }
                    }
                }
            }
        }
        if attributionDepth < 4, let attr = dict["PersonaAttributions"] as? [Any] {
            for item in attr {
                guard let eDict = item as? [String: Any] else { continue }
                let nested = extractDisplayName(eDict, attributionDepth: attributionDepth + 1)
                if !nested.isEmpty { return nested }
            }
        }
        return ""
    }

    /// Job title often lives on the persona root, but compose-style `PersonaAttributions` may carry it on child objects.
    private static func extractJobTitle(_ dict: [String: Any], attributionDepth: Int) -> String? {
        for key in ["JobTitle", "Title", "CompanyName", "Department"] {
            if let s = dict[key] as? String {
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { return t }
            }
        }
        // Plural arrays returned by Exchange when requesting PersonaTitles/PersonaCompanyName/PersonaDepartments.
        for key in ["Titles", "BusinessTitles", "CompanyNames", "Departments"] {
            if let arr = dict[key] as? [Any] {
                if let s = firstNonEmptyValue(in: arr) { return s }
            }
        }
        if attributionDepth < 4, let attr = dict["PersonaAttributions"] as? [Any] {
            for item in attr {
                guard let eDict = item as? [String: Any] else { continue }
                if let nested = extractJobTitle(eDict, attributionDepth: attributionDepth + 1) {
                    return nested
                }
            }
        }
        return nil
    }

    /// Exchange persona array fields ship rows either as plain strings or as `{Value: "..."}` (sometimes with
    /// other metadata). Return the first non-empty trimmed string.
    private static func firstNonEmptyValue(in arr: [Any]) -> String? {
        for item in arr {
            if let s = item as? String {
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { return t }
            }
            if let eDict = item as? [String: Any] {
                for k in ["Value", "DisplayName", "Name"] {
                    if let s = eDict[k] as? String {
                        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !t.isEmpty { return t }
                    }
                }
            }
        }
        return nil
    }

    private static func extractPrimaryEmail(_ dict: [String: Any], attributionDepth: Int = 0) -> String? {
        if let s = dict["SMTPAddress"] as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return t }
        }
        if let s = dict["EmailAddress"] as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return t }
        }
        if let nested = dict["EmailAddress"] as? [String: Any] {
            if let s = nested["EmailAddress"] as? String ?? nested["Address"] as? String {
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { return t }
            }
        }
        if let arr = dict["EmailAddresses"] as? [Any] {
            for item in arr {
                if let eDict = item as? [String: Any] {
                    if let s = eDict["EmailAddress"] as? String ?? eDict["Address"] as? String {
                        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !t.isEmpty { return t }
                    }
                } else if let s = item as? String {
                    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty { return t }
                }
            }
        }
        if let mailbox = dict["Mailbox"] as? [String: Any],
           let s = mailbox["EmailAddress"] as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return t }
        }
        if attributionDepth < 4, let attr = dict["PersonaAttributions"] as? [Any] {
            for item in attr {
                if let eDict = item as? [String: Any],
                   let nested = extractPrimaryEmail(eDict, attributionDepth: attributionDepth + 1) {
                    return nested
                }
            }
        }
        return nil
    }
}
