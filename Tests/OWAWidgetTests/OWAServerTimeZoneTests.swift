import XCTest
@testable import OWAWidget

final class OWAServerTimeZoneTests: XCTestCase {
    func testEveryDisplayTimeZoneHasItsOwnWindowsID() {
        // The settings picker offers these zones; a user who sets the Mac clock to one of them
        // must not be silently treated as Moscow by the server.
        for identifier in DisplayTimeZoneOption.curatedIdentifiers {
            let zone = TimeZone(identifier: identifier)!
            XCTAssertNotNil(OWAServerTimeZone.windowsIDsByIANA[identifier], identifier)
            XCTAssertEqual(OWAServerTimeZone.resolve(zone).zone.identifier, identifier)
        }
    }

    func testNovosibirskIsNotTreatedAsMoscow() {
        let resolved = OWAServerTimeZone.resolve(TimeZone(identifier: "Asia/Novosibirsk")!)
        XCTAssertEqual(resolved.windowsID, "N. Central Asia Standard Time")
        XCTAssertEqual(resolved.zone.identifier, "Asia/Novosibirsk")
    }

    func testEveryTableEntryIsAKnownIANAZone() {
        for identifier in OWAServerTimeZone.windowsIDsByIANA.keys {
            XCTAssertNotNil(TimeZone(identifier: identifier), identifier)
        }
    }

    func testUnknownZoneFallsBackToMoscowForBothHeaderAndDates() {
        let resolved = OWAServerTimeZone.resolve(TimeZone(identifier: "Pacific/Fiji")!)
        XCTAssertEqual(resolved, .fallback)
        XCTAssertEqual(resolved.windowsID, "Russian Standard Time")
        XCTAssertEqual(resolved.zone.identifier, "Europe/Moscow")
    }

    func testCalendarViewRangeIsWrittenInTheZoneTheHeaderNames() throws {
        // 2023-11-14T22:13:20Z: 01:13 next day in Moscow, 05:13 in Novosibirsk.
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let novosibirsk = OWAServerTimeZone.resolve(TimeZone(identifier: "Asia/Novosibirsk")!)

        let payload = OWACalendarViewRequestPayload.make(
            start: start,
            end: start.addingTimeInterval(3_600),
            serverTimeZone: novosibirsk,
            folderIdentifier: nil
        )

        let body = try XCTUnwrap(payload["Body"] as? [String: Any])
        XCTAssertEqual(body["RangeStart"] as? String, "2023-11-15T05:13:20")
        let header = try XCTUnwrap(payload["Header"] as? [String: Any])
        let context = try XCTUnwrap(header["TimeZoneContext"] as? [String: Any])
        let definition = try XCTUnwrap(context["TimeZoneDefinition"] as? [String: Any])
        XCTAssertEqual(definition["Id"] as? String, "N. Central Asia Standard Time")
    }

    func testAvailabilityWindowFollowsTheFallbackZoneToo() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let payload = OWAUserAvailabilityPayload.make(
            emails: ["a@x.com"],
            start: start,
            end: start.addingTimeInterval(86_400),
            serverTimeZone: OWAServerTimeZone.resolve(TimeZone(identifier: "Pacific/Fiji")!)
        )

        let request = try XCTUnwrap(payload["request"] as? [String: Any])
        let body = try XCTUnwrap(request["Body"] as? [String: Any])
        let options = try XCTUnwrap(body["FreeBusyViewOptions"] as? [String: Any])
        let window = try XCTUnwrap(options["TimeWindow"] as? [String: Any])
        XCTAssertEqual(window["StartTime"] as? String, "2023-11-15T01:13:20")
    }
}
