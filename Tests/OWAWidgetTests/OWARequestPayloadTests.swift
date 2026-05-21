import XCTest
@testable import OWAWidget

final class OWARequestPayloadTests: XCTestCase {
    func testCalendarViewRequestUsesOWAContractVersion() throws {
        let payload = OWACalendarViewRequestPayload.make(
            start: Date(timeIntervalSince1970: 0),
            end: Date(timeIntervalSince1970: 3_600),
            timezoneID: "Russian Standard Time",
            folderIdentifier: nil
        )

        let header = try XCTUnwrap(payload["Header"] as? [String: Any])
        XCTAssertEqual(header["RequestServerVersion"] as? String, "V2017_08_18")
    }

    func testCalendarViewRequestFormatsRangeWithoutMilliseconds() throws {
        let payload = OWACalendarViewRequestPayload.make(
            start: Date(timeIntervalSince1970: 0),
            end: Date(timeIntervalSince1970: 3_600),
            timezoneID: "Russian Standard Time",
            folderIdentifier: nil
        )

        let body = try XCTUnwrap(payload["Body"] as? [String: Any])
        XCTAssertFalse(try XCTUnwrap(body["RangeStart"] as? String).contains("."))
        XCTAssertFalse(try XCTUnwrap(body["RangeEnd"] as? String).contains("."))
    }

    func testCalendarViewRequestUsesConcreteFolderIDWhenAvailable() throws {
        let payload = OWACalendarViewRequestPayload.make(
            start: Date(timeIntervalSince1970: 0),
            end: Date(timeIntervalSince1970: 3_600),
            timezoneID: "Russian Standard Time",
            folderIdentifier: OWAFolderIdentifier(id: "folder-id", changeKey: "change-key")
        )

        let body = try XCTUnwrap(payload["Body"] as? [String: Any])
        let calendarID = try XCTUnwrap(body["CalendarId"] as? [String: Any])
        let baseFolderID = try XCTUnwrap(calendarID["BaseFolderId"] as? [String: Any])

        XCTAssertEqual(calendarID["__type"] as? String, "TargetFolderId:#Exchange")
        XCTAssertEqual(baseFolderID["__type"] as? String, "FolderId:#Exchange")
        XCTAssertEqual(baseFolderID["Id"] as? String, "folder-id")
        XCTAssertEqual(baseFolderID["ChangeKey"] as? String, "change-key")
    }

    func testCalendarFoldersParserPrefersDefaultCalendarFolder() throws {
        let json = """
        {
          "Body": {
            "CalendarFolders": [
              {
                "DisplayName": "Shared",
                "FolderId": {
                  "Id": "shared-folder",
                  "ChangeKey": "shared-change"
                }
              },
              {
                "DisplayName": "Calendar",
                "DistinguishedFolderId": "calendar",
                "IsDefaultCalendar": true,
                "FolderId": {
                  "Id": "default-folder",
                  "ChangeKey": "default-change"
                }
              }
            ]
          }
        }
        """

        let folder = OWACalendarFoldersParser.defaultCalendarFolderIdentifier(from: Data(json.utf8))

        XCTAssertEqual(folder, OWAFolderIdentifier(id: "default-folder", changeKey: "default-change"))
    }

    func testOWAErrorRecognizesAbstractClassHTTPError() {
        let body = """
        {"Body":{"FaultMessage":"Cannot create an abstract class."}}
        """

        XCTAssertTrue(
            OWAError.isAbstractClassHTTPError(
                OWAError.httpError(500, body)
            )
        )
        XCTAssertFalse(
            OWAError.isAbstractClassHTTPError(
                OWAError.httpError(500, #"{"Body":{"FaultMessage":"Different server fault."}}"#)
            )
        )
        XCTAssertFalse(
            OWAError.isAbstractClassHTTPError(
                OWAError.httpError(503, body)
            )
        )
    }

    func testStartupRetryPolicyRetriesAbstractClassOnlyAfterFreshAuth() {
        let error = OWAError.httpError(
            500,
            #"{"Body":{"FaultMessage":"Cannot create an abstract class."}}"#
        )

        XCTAssertEqual(
            OWAStartupRetryPolicy.delayBeforeRetry(
                attempt: 0,
                error: error,
                afterFreshAuth: true
            ),
            .milliseconds(700)
        )
        XCTAssertEqual(
            OWAStartupRetryPolicy.delayBeforeRetry(
                attempt: 1,
                error: error,
                afterFreshAuth: true
            ),
            .milliseconds(1_500)
        )
        XCTAssertEqual(
            OWAStartupRetryPolicy.delayBeforeRetry(
                attempt: 4,
                error: error,
                afterFreshAuth: true
            ),
            .seconds(10)
        )
        XCTAssertEqual(
            OWAStartupRetryPolicy.delayBeforeRetry(
                attempt: 5,
                error: error,
                afterFreshAuth: true
            ),
            .seconds(20)
        )
        XCTAssertNil(
            OWAStartupRetryPolicy.delayBeforeRetry(
                attempt: 0,
                error: error,
                afterFreshAuth: false
            )
        )
    }

    func testStartupRetryPolicyStopsAfterConfiguredAttempts() {
        let error = OWAError.httpError(
            500,
            #"{"Body":{"FaultMessage":"Cannot create an abstract class."}}"#
        )

        XCTAssertNil(
            OWAStartupRetryPolicy.delayBeforeRetry(
                attempt: 6,
                error: error,
                afterFreshAuth: true
            )
        )
    }

    func testStartupRetryPolicyDoesNotRetryOtherErrors() {
        XCTAssertNil(
            OWAStartupRetryPolicy.delayBeforeRetry(
                attempt: 0,
                error: OWAError.httpError(500, #"{"Body":{"FaultMessage":"Different server fault."}}"#),
                afterFreshAuth: true
            )
        )
    }

    func testFindPeopleComposeCalendarHARPayloadMatchesBrowserShape() throws {
        let payload = OWAFindPeoplePayload.makeComposeCalendarHAR(
            query: "Коваленко",
            timezoneID: "Russian Standard Time"
        )
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: payload))
        XCTAssertEqual(payload["__type"] as? String, "FindPeopleJsonRequest:#Exchange")
        let header = try XCTUnwrap(payload["Header"] as? [String: Any])
        XCTAssertEqual(header["RequestServerVersion"] as? String, "Exchange2013")
        let body = try XCTUnwrap(payload["Body"] as? [String: Any])
        XCTAssertNil(body["ParentFolderId"])
        XCTAssertEqual(body["QueryString"] as? String, "Коваленко")
        XCTAssertEqual(body["SearchPeopleSuggestionIndex"] as? Bool, false)
        XCTAssertNotNil(body["AggregationRestriction"])
        XCTAssertNotNil(body["Context"])
        let personaShape = try XCTUnwrap(body["PersonaShape"] as? [String: Any])
        let addl = try XCTUnwrap(personaShape["AdditionalProperties"] as? [[String: Any]])
        XCTAssertTrue(addl.contains { ($0["FieldURI"] as? String) == "PersonaAttributions" })
    }

    func testUserAvailabilityPayloadSerializesMailboxesAndWindow() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let end = start.addingTimeInterval(86_400)
        let payload = OWAUserAvailabilityPayload.make(
            emails: ["a@x.com", "b@y.org"],
            start: start,
            end: end,
            timezoneID: "Russian Standard Time"
        )
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: payload))
        let request = try XCTUnwrap(payload["request"] as? [String: Any])
        XCTAssertEqual(request["__type"] as? String, "GetUserAvailabilityInternalJsonRequest:#Exchange")
        let body = try XCTUnwrap(request["Body"] as? [String: Any])
        let mailboxes = try XCTUnwrap(body["MailboxDataArray"] as? [[String: Any]])
        XCTAssertEqual(mailboxes.count, 2)
        let firstMailbox = try XCTUnwrap(mailboxes.first?["Email"] as? [String: Any])
        XCTAssertEqual(firstMailbox["__type"] as? String, "EmailAddress:#Exchange")
        XCTAssertEqual(firstMailbox["Address"] as? String, "a@x.com")
        let opts = try XCTUnwrap(body["FreeBusyViewOptions"] as? [String: Any])
        XCTAssertEqual((opts["MergedFreeBusyIntervalInMinutes"] as? NSNumber)?.intValue, 30)
        XCTAssertEqual(opts["RequestedView"] as? String, "DetailedMerged")
        let tw = try XCTUnwrap(opts["TimeWindow"] as? [String: Any])
        XCTAssertNotNil(tw["StartTime"] as? String)
        XCTAssertNotNil(tw["EndTime"] as? String)
    }

    func testCalendarBodyHTMLEscapesUserInputAndPreservesLineBreaks() throws {
        let html = OWACreateCalendarEventPayload.calendarBodyHTML(plainAgenda: "Goals\nDiscuss <budget> & \"plans\"")
        XCTAssertTrue(html.contains("Goals"))
        XCTAssertTrue(html.contains("<br/>"))
        XCTAssertTrue(html.contains("&lt;budget&gt;"))
        XCTAssertTrue(html.contains("&amp;"))
        XCTAssertTrue(html.contains("&quot;plans&quot;"))
    }

    func testCalendarBodyHTMLNeutralizesCDATAEndDelimiter() throws {
        // SOAP помещает HTML внутрь CDATA — ]]> в пользовательском вводе сломал бы парсинг.
        let html = OWACreateCalendarEventPayload.calendarBodyHTML(plainAgenda: "before ]]> after")
        XCTAssertFalse(html.contains("]]>"), "raw ]]> must not survive into CDATA section")
        // После защиты подставляется пробел, дальше `>` экранируется HTML-эскейпом.
        XCTAssertTrue(html.contains("]] &gt;"))
    }

    func testCalendarBodyHTMLReturnsEmptyBodyForBlankAgenda() throws {
        let html = OWACreateCalendarEventPayload.calendarBodyHTML(plainAgenda: "   \n  ")
        XCTAssertTrue(html.contains("<br>"), "blank agenda yields an empty-body placeholder")
    }
}
