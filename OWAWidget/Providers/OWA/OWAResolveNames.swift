import Foundation

/// EWS `ResolveNames` with the full contact from the address book: title, department, office,
/// city and the manager. Shape checked on Exchange 2019 (2026-11-21).
enum OWAResolveNamesPayload {
    /// `ContactDataShape="AllProperties"` (Exchange2010_SP2+) is what brings `ManagerMailbox` and
    /// `DirectReports`. `ActiveDirectory` only: the user's own contacts are not the org chart.
    static func soap(email: String) -> String {
        """
        <?xml version="1.0" encoding="utf-8"?>
        <soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/" \
        xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types" \
        xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages">
          <soap:Header>
            <t:RequestServerVersion Version="Exchange2013_SP1"/>
          </soap:Header>
          <soap:Body>
            <m:ResolveNames ReturnFullContactData="true" SearchScope="ActiveDirectory" ContactDataShape="AllProperties">
              <m:UnresolvedEntry>\(OWACreateCalendarEventPayload.escapeXML(email))</m:UnresolvedEntry>
            </m:ResolveNames>
          </soap:Body>
        </soap:Envelope>
        """
    }

    /// Answers, not failures: nobody by that address, or several candidates.
    static let acceptedCodes: Set<String> = ["ErrorNameResolutionNoResults", "ErrorNameResolutionMultipleResults"]
}

enum OWAResolveNamesParser {
    /// The entry for `email`, or `nil` when the address book has nobody with that address.
    /// Several candidates (a partial match) count as nobody unless one has exactly that address.
    static func profile(fromXML xml: String, email: String) -> PersonProfile? {
        let wanted = email.lowercased()
        return resolutions(fromXML: xml)
            .first { $0.email.lowercased() == wanted || $0.aliases.contains(wanted) }?
            .profile
    }

    struct Resolution {
        var profile: PersonProfile
        var email: String { profile.email }
        /// Lowercased SMTP addresses from `EmailAddresses` (`smtp:` prefixes dropped).
        var aliases: Set<String>
    }

    static func resolutions(fromXML xml: String) -> [Resolution] {
        let collector = Collector()
        let parser = XMLParser(data: Data(xml.utf8))
        parser.shouldProcessNamespaces = true
        parser.delegate = collector
        guard parser.parse() else { return [] }
        return collector.results
    }

    private final class Collector: NSObject, XMLParserDelegate {
        var results: [Resolution] = []
        private var path: [String] = []
        private var text = ""
        private var entryKey: String?
        private var fields: [String: String] = [:]
        private var manager: (name: String?, email: String?) = (nil, nil)
        private var directReports = 0
        private var aliases = Set<String>()

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            path.append(name)
            text = ""
            if name == "Resolution" {
                fields = [:]
                manager = (nil, nil)
                directReports = 0
                aliases = []
            }
            if name == "Entry" { entryKey = attributes["Key"] }
            if name == "Mailbox", path.dropLast().last == "DirectReports" { directReports += 1 }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            defer { path.removeLast(); text = "" }
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let at = path.lastIndex(of: "Resolution") else { return }
            let inner = Array(path[(at + 1)...])
            switch inner {
            case ["Mailbox", "Name"]: fields["mailboxName"] = value
            case ["Mailbox", "EmailAddress"]: fields["email"] = value
            case ["Mailbox", "MailboxType"]: fields["mailboxType"] = value
            case ["Contact", "DisplayName"]: fields["displayName"] = value
            case ["Contact", "JobTitle"]: fields["title"] = value
            case ["Contact", "Department"]: fields["department"] = value
            case ["Contact", "OfficeLocation"]: fields["office"] = value
            case ["Contact", "CompanyName"]: fields["company"] = value
            case ["Contact", "PhysicalAddresses", "Entry", "City"] where entryKey == "Business": fields["city"] = value
            case ["Contact", "EmailAddresses", "Entry"]:
                let lower = value.lowercased()
                if lower.hasPrefix("smtp:") { aliases.insert(String(lower.dropFirst(5))) }
            case ["Contact", "ManagerMailbox", "Mailbox", "Name"]: manager.name = value
            case ["Contact", "ManagerMailbox", "Mailbox", "EmailAddress"]: manager.email = value
            case []:
                finishResolution()
            default:
                break
            }
        }

        private func finishResolution() {
            func field(_ key: String) -> String? {
                guard let value = fields[key], !value.isEmpty else { return nil }
                return value
            }
            guard let email = field("email") else { return }
            let managerPerson = manager.email.flatMap { address -> OrgPerson? in
                guard !address.isEmpty else { return nil }
                let name = manager.name.flatMap { $0.isEmpty ? nil : $0 } ?? address
                return OrgPerson(name: name, email: address, title: nil)
            }
            let profile = PersonProfile(
                // The mailbox name is often the sign-in alias; the contact has the display name.
                name: field("displayName") ?? field("mailboxName") ?? email,
                email: email,
                isDistributionList: field("mailboxType").map { $0.hasSuffix("DL") } ?? false,
                title: field("title"),
                department: field("department"),
                office: field("office"),
                city: field("city"),
                company: field("company"),
                manager: managerPerson,
                directReportsCount: directReports
            )
            results.append(Resolution(profile: profile, aliases: aliases))
        }
    }
}
