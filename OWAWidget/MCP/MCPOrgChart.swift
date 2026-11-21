import Foundation

/// Address book answers (`get_my_org`, `get_person_profile`), in memory only. The organization
/// changes rarely and a chart for a manager of a hundred people weighs ~120 KB, so a day is a fair
/// lifetime. "Not in the address book" (`nil`) is remembered too.
struct MCPDirectoryCache<Value: Sendable> {
    static var lifetime: TimeInterval { 24 * 3600 }
    static var maxEntries: Int { 300 }

    private var entries: [String: (date: Date, value: Value?)] = [:]

    func lookup(_ email: String, account: UUID, now: Date) -> (date: Date, value: Value?)? {
        guard let entry = entries[Self.key(email, account)], now.timeIntervalSince(entry.date) < Self.lifetime else { return nil }
        return entry
    }

    mutating func store(_ value: Value?, for email: String, account: UUID, now: Date) {
        if entries.count >= Self.maxEntries {
            entries = entries.filter { now.timeIntervalSince($0.value.date) < Self.lifetime }
            while entries.count >= Self.maxEntries, let oldest = entries.min(by: { $0.value.date < $1.value.date })?.key {
                entries[oldest] = nil
            }
        }
        entries[Self.key(email, account)] = (now, value)
    }

    private static func key(_ email: String, _ account: UUID) -> String {
        "\(account.uuidString)|\(email.lowercased())"
    }
}

typealias MCPOrgCache = MCPDirectoryCache<OrgHierarchy>
typealias MCPProfileCache = MCPDirectoryCache<PersonProfile>

/// JSON of `get_my_org`.
enum MCPOrgChartFormat {
    static func person(_ person: OrgPerson, ownEmail: String?) -> [String: JSONValue] {
        var fields: [String: JSONValue] = [
            "name": .string(person.name),
            "email": .string(person.email),
        ]
        if let title = person.title {
            fields["title"] = .string(title)
        } else {
            // Service and shared mailboxes have no title; a person without one is rare.
            fields["likely_service_mailbox"] = true
        }
        if let ownEmail, person.email.caseInsensitiveCompare(ownEmail) == .orderedSame {
            fields["is_you"] = true
        }
        return fields
    }

    static func people(_ people: [OrgPerson], ownEmail: String?) -> JSONValue {
        .array(people.map { .object(person($0, ownEmail: ownEmail)) })
    }

    /// The person the chart is about. Exchange does not return them on their own: they are in
    /// `Peers`, unless they have no manager.
    static func subject(_ email: String, in hierarchy: OrgHierarchy?, ownEmail: String?) -> [String: JSONValue] {
        if let found = hierarchy?.peers.first(where: { $0.email.caseInsensitiveCompare(email) == .orderedSame }) {
            return person(found, ownEmail: ownEmail)
        }
        var fields: [String: JSONValue] = ["email": .string(email)]
        if let ownEmail, email.caseInsensitiveCompare(ownEmail) == .orderedSame { fields["is_you"] = true }
        return fields
    }

    static func peers(of email: String, in hierarchy: OrgHierarchy) -> [OrgPerson] {
        hierarchy.peers.filter { $0.email.caseInsensitiveCompare(email) != .orderedSame }
    }

    static func profile(_ profile: PersonProfile, asked email: String, asOf: String, ownEmail: String?) -> [String: JSONValue] {
        var fields: [String: JSONValue] = [
            "email": .string(email),
            "in_directory": true,
            "name": .string(profile.name),
            "direct_reports_count": .int(Int64(profile.directReportsCount)),
            "as_of": .string(asOf),
        ]
        if profile.email.caseInsensitiveCompare(email) != .orderedSame { fields["primary_email"] = .string(profile.email) }
        if profile.isDistributionList { fields["is_distribution_list"] = true }
        let optional: [(String, String?)] = [
            ("title", profile.title), ("department", profile.department), ("office", profile.office),
            ("city", profile.city), ("company", profile.company),
        ]
        for (key, value) in optional { if let value { fields[key] = .string(value) } }
        if let manager = profile.manager {
            fields["manager"] = ["name": .string(manager.name), "email": .string(manager.email)]
        }
        if let ownEmail, [email, profile.email].contains(where: { $0.caseInsensitiveCompare(ownEmail) == .orderedSame }) {
            fields["is_you"] = true
        }
        return fields
    }
}
