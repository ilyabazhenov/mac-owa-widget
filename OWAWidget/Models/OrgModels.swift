import Foundation

/// A person in the organization chart, as the address book has them.
struct OrgPerson: Sendable, Equatable {
    let name: String
    let email: String
    /// `nil` when the address book has no title (service mailboxes usually have none).
    let title: String?
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
