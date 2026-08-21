import XCTest
@testable import OWAWidget

/// Account-type capabilities and the on-disk shape of `CalendarAccount`.
///
/// Both matter beyond the model itself: the capabilities decide whether the create-meeting entry
/// points appear at all, and the encoding decides whether accounts written by an older build
/// survive an update.
final class CalendarAccountTypeTests: XCTestCase {

    func testOnlyExchangeAccountsCarryAPassword() {
        XCTAssertTrue(AccountType.owa.requiresPassword)
        XCTAssertFalse(AccountType.eventKit.requiresPassword)
    }

    /// EventKit is read-only, so the create-meeting window must not be offered for it — otherwise
    /// the user fills in a whole form before the provider answers `notSupported`.
    func testOnlyExchangeAccountsCanCreateMeetings() {
        XCTAssertTrue(AccountType.owa.supportsMeetingCreation)
        XCTAssertFalse(AccountType.eventKit.supportsMeetingCreation)
        XCTAssertFalse(AccountType.googleCalendar.supportsMeetingCreation)
    }

    // MARK: - Encoding

    /// Accounts persisted by a build that predates calendar selection must still decode; the new
    /// fields are simply absent.
    func testDecodesAccountWrittenBeforeCalendarSelectionExisted() throws {
        let legacy = """
        {
            "id": "11111111-2222-3333-4444-555555555555",
            "displayName": "Работа",
            "serverURL": "https://mail.example.com",
            "email": "user@example.com",
            "accountType": "owa"
        }
        """.data(using: .utf8)!

        let account = try JSONDecoder().decode(CalendarAccount.self, from: legacy)

        XCTAssertEqual(account.accountType, .owa)
        XCTAssertNil(account.calendarIdentifiers)
        XCTAssertNil(account.sourceIdentifier)
    }

    func testRoundTripsCalendarSelection() throws {
        let account = CalendarAccount(
            displayName: "Google",
            serverURL: "",
            email: "",
            accountType: .eventKit,
            calendarIdentifiers: ["cal-a", "cal-b"],
            sourceIdentifier: "source-1"
        )

        let data = try JSONEncoder().encode(account)
        let decoded = try JSONDecoder().decode(CalendarAccount.self, from: data)

        XCTAssertEqual(decoded.accountType, .eventKit)
        XCTAssertEqual(decoded.calendarIdentifiers, ["cal-a", "cal-b"])
        XCTAssertEqual(decoded.sourceIdentifier, "source-1")
    }

    /// The raw value is what lands on disk; renaming it would orphan every saved account.
    func testRawValuesAreStable() {
        XCTAssertEqual(AccountType.owa.rawValue, "owa")
        XCTAssertEqual(AccountType.eventKit.rawValue, "eventKit")
        XCTAssertEqual(AccountType.googleCalendar.rawValue, "googleCalendar")
    }
}
