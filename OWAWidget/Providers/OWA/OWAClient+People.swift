import Foundation

/// The address book beyond search: someone's place in the organization chart.
extension OWAClient {
    /// One `GetOrganizationHierarchyForPersona` request: manager, the chain above, peers and
    /// direct reports with their titles. `nil` when the address is not in the address book.
    func organizationHierarchy(email: String) async throws -> OrgHierarchy? {
        let data = try await mailServiceCall(
            action: "GetOrganizationHierarchyForPersona",
            payload: OWAOrgHierarchyPayload.make(email: email)
        )
        return OWAOrgHierarchyParser.hierarchy(fromJSONData: data)
    }
}
