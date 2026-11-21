import Foundation

/// A person in the organization chart, as the address book has them.
struct OrgPerson: Sendable, Equatable {
    let name: String
    let email: String
    /// `nil` when the address book has no title (service mailboxes usually have none).
    let title: String?
}

/// What the address book says about one person (EWS `ResolveNames` with the full contact).
struct PersonProfile: Sendable, Equatable {
    let name: String
    /// The primary address, which may differ from the one asked about (an alias).
    let email: String
    let isDistributionList: Bool
    let title: String?
    let department: String?
    let office: String?
    /// From the business address.
    let city: String?
    let company: String?
    /// Name and address only: `ResolveNames` does not give the manager's title.
    let manager: OrgPerson?
    let directReportsCount: Int
}

/// Someone's place in the organization chart: one `GetOrganizationHierarchyForPersona` answer.
struct OrgHierarchy: Sendable, Equatable {
    /// The direct manager; `nil` at the top of the chart.
    var manager: OrgPerson?
    /// The managers above `manager`, from the top of the chart down. The direct manager is not in it.
    var managementChain: [OrgPerson]
    /// Everyone reporting to the same manager. Exchange includes the person themselves.
    var peers: [OrgPerson]
    var directReports: [OrgPerson]
}
