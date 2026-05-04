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
}
