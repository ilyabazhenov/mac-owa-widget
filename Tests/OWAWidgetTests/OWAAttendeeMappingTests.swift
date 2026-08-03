import XCTest
@testable import OWAWidget

/// Verifies the tolerant `GetCalendarEvent` attendee parser: it must locate attendees regardless of
/// wrapper nesting, accept both array and single-object attendee shapes, and map each `ResponseType`.
final class OWAAttendeeMappingTests: XCTestCase {

    private func parse(_ json: String) -> [EventAttendee] {
        OWACalendarEventAttendeesParser.attendees(fromJSONData: Data(json.utf8))
    }

    func testParsesRequiredAndOptionalAttendeesWithResponses() throws {
        // RequiredAttendees as an array, OptionalAttendees as a single object, nested under a wrapper.
        let json = """
        {
          "Body": {
            "__type": "GetCalendarEventResponse:#Exchange",
            "Event": {
              "Subject": "Sync",
              "RequiredAttendees": {
                "Attendee": [
                  { "Mailbox": { "Name": "Иван Иванов", "EmailAddress": "ivan@example.com" }, "ResponseType": "Accept" },
                  { "Mailbox": { "Name": "Пётр Петров", "EmailAddress": "petr@example.com" }, "ResponseType": "NoResponseReceived" }
                ]
              },
              "OptionalAttendees": {
                "Attendee": { "Mailbox": { "Name": "Сергей Сергеев", "EmailAddress": "sergey@example.com" }, "ResponseType": "Decline" }
              }
            }
          }
        }
        """

        let attendees = parse(json)
        XCTAssertEqual(attendees.count, 3)

        let required = attendees.filter { $0.kind == .required }
        let optional = attendees.filter { $0.kind == .optional }
        XCTAssertEqual(required.count, 2)
        XCTAssertEqual(optional.count, 1)

        XCTAssertEqual(required[0].name, "Иван Иванов")
        XCTAssertEqual(required[0].email, "ivan@example.com")
        XCTAssertEqual(required[0].response, .accepted)
        XCTAssertEqual(required[1].response, .notResponded)

        XCTAssertEqual(optional[0].name, "Сергей Сергеев")
        XCTAssertEqual(optional[0].response, .declined)
        XCTAssertEqual(optional[0].kind, .optional)
    }

    func testParsesAttendeesGivenAsBareArray() {
        // Some builds emit the attendee list directly as an array (no "Attendee" wrapper key).
        let json = """
        {
          "RequiredAttendees": [
            { "Mailbox": { "Name": "A", "EmailAddress": "a@x.com" }, "ResponseType": "Tentative" }
          ]
        }
        """
        let attendees = parse(json)
        XCTAssertEqual(attendees.count, 1)
        XCTAssertEqual(attendees[0].name, "A")
        XCTAssertEqual(attendees[0].response, .tentative)
        XCTAssertEqual(attendees[0].kind, .required)
    }

    func testNoAttendeesYieldsEmpty() {
        XCTAssertTrue(parse("{ \"Body\": { \"Event\": { \"Subject\": \"Solo\" } } }").isEmpty)
    }

    func testAttendeeWithoutNameFallsBackToEmail() {
        let json = """
        {
          "RequiredAttendees": {
            "Attendee": { "Mailbox": { "EmailAddress": "noname@example.com" } }
          }
        }
        """
        let attendees = parse(json)
        XCTAssertEqual(attendees.count, 1)
        XCTAssertEqual(attendees[0].name, "noname@example.com")
        XCTAssertEqual(attendees[0].response, .notResponded)
    }

    func testGarbageJSONYieldsEmpty() {
        XCTAssertTrue(parse("not json at all").isEmpty)
    }

    /// Pins the actual corporate OWA (Exchange 15.2) response shape: attendees are a bare array
    /// nested under `Body.ResponseMessages.Items[].Items[]`, mailboxes carry `RoutingType`, and the
    /// server reports `ResponseType: "Unknown"` for tracked-but-unanswered invitees.
    func testParsesRealGetCalendarEventResponseShape() {
        let json = """
        {
          "Header": { "ServerVersionInfo": { "MajorVersion": 15 } },
          "Body": {
            "__type": "GetCalendarEventJsonResponse:#Exchange",
            "ResponseMessages": {
              "__type": "ArrayOfResponseMessages:#Exchange",
              "Items": [
                {
                  "__type": "GetCalendarEventResponseMessage:#Exchange",
                  "ResponseClass": "Success",
                  "Items": [
                    {
                      "__type": "CalendarEvent:#Exchange",
                      "Subject": "Обмен опытом",
                      "Organizer": { "Mailbox": { "Name": "Петров Михаил", "EmailAddress": "MPetrov@example.ru", "RoutingType": "SMTP" } },
                      "RequiredAttendees": [
                        { "Mailbox": { "Name": "Петров Михаил", "EmailAddress": "MPetrov@example.ru", "RoutingType": "SMTP" }, "ResponseType": "Unknown" },
                        { "Mailbox": { "Name": "Иванов Илья", "EmailAddress": "IIvanov@example.ru", "RoutingType": "SMTP" }, "ResponseType": "Accept" }
                      ],
                      "OptionalAttendees": [
                        { "Mailbox": { "Name": "Сидоров Владислав", "EmailAddress": "VSidorov@example.ru", "RoutingType": "SMTP" }, "ResponseType": "Decline" }
                      ],
                      "Resources": []
                    }
                  ]
                }
              ]
            }
          }
        }
        """
        let attendees = parse(json)
        XCTAssertEqual(attendees.count, 3)

        let required = attendees.filter { $0.kind == .required }
        XCTAssertEqual(required.count, 2)
        XCTAssertEqual(required[0].name, "Петров Михаил")
        XCTAssertEqual(required[0].email, "MPetrov@example.ru")
        XCTAssertEqual(required[0].response, .notResponded) // "Unknown" → no response
        XCTAssertEqual(required[1].response, .accepted)

        let optional = attendees.filter { $0.kind == .optional }
        XCTAssertEqual(optional.count, 1)
        XCTAssertEqual(optional[0].response, .declined)
    }

    func testMapsOrganizerAndUnknownResponseTypes() {
        let json = """
        {
          "RequiredAttendees": [
            { "Mailbox": { "Name": "Org" }, "ResponseType": "Organizer" },
            { "Mailbox": { "Name": "Unk" }, "ResponseType": "Unknown" },
            { "Mailbox": { "Name": "Missing" } }
          ]
        }
        """
        let byName = Dictionary(uniqueKeysWithValues: parse(json).map { ($0.name, $0.response) })
        XCTAssertEqual(byName["Org"], .organizer)
        XCTAssertEqual(byName["Unk"], .notResponded)
        XCTAssertEqual(byName["Missing"], .notResponded)
    }
}
