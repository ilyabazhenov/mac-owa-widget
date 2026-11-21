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

    /// One EWS `ResolveNames` request: title, department, office, city and manager.
    /// `nil` when the address book has nobody with this address.
    func personProfile(email: String) async throws -> PersonProfile? {
        let body = try await ewsCall(
            action: "ResolveNames",
            soap: OWAResolveNamesPayload.soap(email: email),
            mayRepeat: true,
            note: "",
            area: "People",
            acceptedCodes: OWAResolveNamesPayload.acceptedCodes
        )
        return OWAResolveNamesParser.profile(fromXML: body, email: email)
    }
}
