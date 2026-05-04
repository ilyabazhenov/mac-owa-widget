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
}
