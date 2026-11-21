import Foundation

/// Parses OWA `service.svc?action=GetOrganizationHierarchyForPersona`.
///
/// Shape checked on Exchange 2019 (2026-11-21): the four lists sit at the top level, without
/// `Body`; an empty list comes as `null`; a person outside the address book (an outside address,
/// a distribution list) gets `200` with an empty body.
enum OWAOrgHierarchyParser {
    private static let keys = ["Manager", "ManagementChain", "Peers", "DirectReports"]

    /// `nil` when the answer says nothing about the person: they are not in the address book.
    static func hierarchy(fromJSONData data: Data) -> OrgHierarchy? {
        guard !data.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let root: [String: Any]
        if keys.contains(where: { json[$0] != nil }) {
            root = json
        } else if let body = json["Body"] as? [String: Any], keys.contains(where: { body[$0] != nil }) {
            root = body
        } else {
            return nil
        }
        let hierarchy = OrgHierarchy(
            manager: (root["Manager"] as? [String: Any]).flatMap(person),
            managementChain: people(root["ManagementChain"]),
            peers: people(root["Peers"]),
            directReports: people(root["DirectReports"])
        )
        let isEmpty = hierarchy.manager == nil && hierarchy.managementChain.isEmpty
            && hierarchy.peers.isEmpty && hierarchy.directReports.isEmpty
        return isEmpty ? nil : hierarchy
    }

    private static func people(_ value: Any?) -> [OrgPerson] {
        guard let items = value as? [Any] else { return [] }
        var seen = Set<String>()
        return items.compactMap { ($0 as? [String: Any]).flatMap(person) }
            .filter { seen.insert($0.email.lowercased()).inserted }
    }

    private static func person(_ dict: [String: Any]) -> OrgPerson? {
        let address: String?
        if let nested = dict["EmailAddress"] as? [String: Any] {
            address = nested["EmailAddress"] as? String
        } else {
            address = dict["EmailAddress"] as? String
        }
        guard let email = trimmed(address), email.contains("@") else { return nil }
        let name = trimmed(dict["DisplayName"] as? String) ?? email
        var title = trimmed(dict["Title"] as? String)
        if title == nil, let titles = dict["TitlesArray"] as? [Any] {
            title = titles.lazy.compactMap { trimmed(($0 as? [String: Any])?["Value"] as? String) }.first
        }
        return OrgPerson(name: name, email: email, title: title)
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
