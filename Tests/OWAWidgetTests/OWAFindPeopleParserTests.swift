import XCTest
@testable import OWAWidget

final class OWAFindPeopleParserTests: XCTestCase {

    func testParsesNestedResultSetItems() throws {
        let data = Data(
            """
            {
              "Body": {
                "ResultSet": {
                  "Items": [
                    {
                      "DisplayName": "Ivan Petrov",
                      "EmailAddress": { "EmailAddress": "ivan.petrov@example.com" },
                      "JobTitle": "Engineer"
                    }
                  ]
                }
              }
            }
            """.utf8
        )

        let list = OWAFindPeopleParser.attendees(fromJSONData: data)
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].displayName, "Ivan Petrov")
        XCTAssertEqual(list[0].email, "ivan.petrov@example.com")
        XCTAssertEqual(list[0].jobTitle, "Engineer")
    }

    func testDedupesByEmailCaseInsensitive() throws {
        let data = Data(
            """
            {
              "hits": [
                { "DisplayName": "A", "EmailAddress": "same@x.com" },
                { "DisplayName": "B", "EmailAddress": "SAME@x.com" }
              ]
            }
            """.utf8
        )

        let list = OWAFindPeopleParser.attendees(fromJSONData: data)
        XCTAssertEqual(list.count, 1)
    }

    func testParsesEmailFromPersonaAttributionsWithParentDisplayName() throws {
        let data = Data(
            """
            {
              "Body": {
                "ResultSet": {
                  "Items": [
                    {
                      "DisplayName": "Kovalenko Ivan",
                      "PersonaAttributions": [
                        {
                          "EmailAddress": "ivan.kovalenko@example.com",
                          "JobTitle": "Lead Engineer"
                        }
                      ]
                    }
                  ]
                }
              }
            }
            """.utf8
        )

        let list = OWAFindPeopleParser.attendees(fromJSONData: data)
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].displayName, "Kovalenko Ivan")
        XCTAssertEqual(list[0].email, "ivan.kovalenko@example.com")
        XCTAssertEqual(list[0].jobTitle, "Lead Engineer")
    }

    func testParsesJobTitleFromBusinessTitlesAttributedValue() throws {
        let data = Data(
            """
            {
              "hits": [
                {
                  "DisplayName": "Alex Sidorov",
                  "EmailAddress": "alex.s@example.com",
                  "BusinessTitles": [{ "Value": "Product Manager" }]
                }
              ]
            }
            """.utf8
        )

        let list = OWAFindPeopleParser.attendees(fromJSONData: data)
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].jobTitle, "Product Manager")
    }

    func testParsesDisplayNamesAttributedValue() throws {
        let data = Data(
            """
            {
              "hits": [
                {
                  "DisplayNames": [{ "Value": "Maria Petrova" }],
                  "SMTPAddress": "maria.p@example.com"
                }
              ]
            }
            """.utf8
        )

        let list = OWAFindPeopleParser.attendees(fromJSONData: data)
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].displayName, "Maria Petrova")
        XCTAssertEqual(list[0].email, "maria.p@example.com")
    }

    func testSkipsRequestShapedEnvelope() throws {
        let data = Data(
            """
            {
              "Body": {
                "__type": "FindPeopleRequest:#Exchange",
                "QueryString": "x",
                "Nested": {
                  "DisplayName": "Ghost",
                  "EmailAddress": "ghost@example.com"
                }
              }
            }
            """.utf8
        )

        let list = OWAFindPeopleParser.attendees(fromJSONData: data)
        XCTAssertTrue(list.isEmpty)
    }
}
