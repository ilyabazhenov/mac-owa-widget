import XCTest
@testable import OWAWidget

final class OWAOrgHierarchyParserTests: XCTestCase {

    /// Anonymized shape of a live Exchange 2019 answer (2026-11-21).
    func testParsesTheFourListsWithTitles() throws {
        let data = Data(
            """
            {
              "DirectReports": [
                { "PersonaId": { "Id": "A1" }, "DisplayName": "Bot_AI", "Title": "",
                  "EmailAddress": { "EmailAddress": "bot_ai@corp.ru", "RoutingType": "SMTP", "MailboxType": "Mailbox" },
                  "TitlesArray": [{ "Value": "", "Attributions": ["0"] }], "ADObjectId": "x" }
              ],
              "ManagementChain": [
                { "DisplayName": "Первый П.", "Title": "Председатель", "EmailAddress": { "EmailAddress": "ceo@corp.ru" } },
                { "DisplayName": "Второй В.", "Title": null, "TitlesArray": [{ "Value": "Директор" }],
                  "EmailAddress": { "EmailAddress": "vp@corp.ru" } }
              ],
              "Manager": { "DisplayName": "Чернов М.", "Title": "Руководитель", "EmailAddress": { "EmailAddress": "boss@corp.ru" } },
              "Peers": [
                { "DisplayName": "Баженов И.", "Title": "Архитектор", "EmailAddress": { "EmailAddress": "me@corp.ru" } },
                { "DisplayName": "Дубль", "Title": "Архитектор", "EmailAddress": { "EmailAddress": "ME@corp.ru" } },
                { "DisplayName": "Без адреса", "Title": "Архитектор", "EmailAddress": null }
              ]
            }
            """.utf8
        )

        let org = try XCTUnwrap(OWAOrgHierarchyParser.hierarchy(fromJSONData: data))
        XCTAssertEqual(org.manager, OrgPerson(name: "Чернов М.", email: "boss@corp.ru", title: "Руководитель"))
        XCTAssertEqual(org.managementChain.map(\.email), ["ceo@corp.ru", "vp@corp.ru"])
        XCTAssertEqual(org.managementChain.last?.title, "Директор")
        XCTAssertEqual(org.peers.map(\.email), ["me@corp.ru"])
        XCTAssertEqual(org.directReports, [OrgPerson(name: "Bot_AI", email: "bot_ai@corp.ru", title: nil)])
    }

    func testNullListsAreEmpty() throws {
        let data = Data(#"{"Manager":{"DisplayName":"M","EmailAddress":{"EmailAddress":"m@corp.ru"}},"ManagementChain":[],"Peers":null,"DirectReports":null}"#.utf8)
        let org = try XCTUnwrap(OWAOrgHierarchyParser.hierarchy(fromJSONData: data))
        XCTAssertEqual(org.manager?.email, "m@corp.ru")
        XCTAssertNil(org.manager?.title)
        XCTAssertTrue(org.peers.isEmpty)
        XCTAssertTrue(org.directReports.isEmpty)
    }

    func testEmptyBodyOrUnknownShapeMeansNotInTheDirectory() {
        XCTAssertNil(OWAOrgHierarchyParser.hierarchy(fromJSONData: Data()))
        XCTAssertNil(OWAOrgHierarchyParser.hierarchy(fromJSONData: Data(#"{"Body":{"ResponseCode":"ErrorInternalServerError"}}"#.utf8)))
        XCTAssertNil(OWAOrgHierarchyParser.hierarchy(fromJSONData: Data(#"{"Manager":null,"ManagementChain":null,"Peers":null,"DirectReports":null}"#.utf8)))
    }

    func testAcceptsTheListsInsideBody() throws {
        let data = Data(#"{"Body":{"Manager":{"DisplayName":"M","Title":"T","EmailAddress":{"EmailAddress":"m@corp.ru"}}}}"#.utf8)
        XCTAssertEqual(OWAOrgHierarchyParser.hierarchy(fromJSONData: data)?.manager?.title, "T")
    }

    func testPayloadMatchesTheBrowserShape() throws {
        let payload = OWAOrgHierarchyPayload.make(email: "me@corp.ru")
        let text = OWAClient.serializeJSONTypeFirst(payload)
        XCTAssertEqual(
            text,
            #"{"getOrganizationHierarchyForPersonaRequest":{"__type":"GetOrganizationHierarchyForPersonaRequest:#Exchange","EmailAddress":{"__type":"EmailAddress:#Exchange","EmailAddress":"me@corp.ru"}}}"#
        )
    }
}
