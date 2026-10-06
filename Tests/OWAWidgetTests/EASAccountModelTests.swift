import XCTest
@testable import OWAWidget

/// `CalendarAccount` is persisted, so adding a field to it is a storage migration.
///
/// The failure being guarded against is silent: if an account written before `easDevice`
/// existed stopped decoding, the accounts list would come back empty and the app would
/// present its first-run state — inviting the user to re-enter accounts over the ones still
/// on disk.
final class EASAccountModelTests: XCTestCase {

    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    // MARK: Backward compatibility

    func testDecodesAccountWrittenBeforeDeviceProfileExisted() throws {
        let legacy = """
        {
          "id": "6F24CAD5-99A5-4F1A-8902-46B8C68FAE8D",
          "displayName": "Work",
          "serverURL": "owa.example.com",
          "email": "DOMAIN\\\\user",
          "accountType": "owa"
        }
        """.data(using: .utf8)!

        let account = try decoder.decode(CalendarAccount.self, from: legacy)

        XCTAssertEqual(account.displayName, "Work")
        XCTAssertEqual(account.email, #"DOMAIN\user"#)
        XCTAssertEqual(account.accountType, .owa)
        XCTAssertNil(account.easDevice)
        // An absent profile must resolve to defaults, never to empty strings.
        XCTAssertEqual(account.resolvedDeviceProfile, EASDeviceProfile.default)
    }

    func testDecodesLegacyAccountList() throws {
        // The store holds an array; one undecodable element loses the whole list.
        let legacy = """
        [
          {"id":"6F24CAD5-99A5-4F1A-8902-46B8C68FAE8D","displayName":"A",
           "serverURL":"a.example.com","email":"a","accountType":"owa"},
          {"id":"7F24CAD5-99A5-4F1A-8902-46B8C68FAE8D","displayName":"B",
           "serverURL":"","email":"","accountType":"eventKit","calendarIdentifiers":["x"]}
        ]
        """.data(using: .utf8)!

        let accounts = try decoder.decode([CalendarAccount].self, from: legacy)
        XCTAssertEqual(accounts.count, 2)
        XCTAssertEqual(accounts[1].accountType, .eventKit)
    }

    func testDeviceProfileSurvivesRoundTrip() throws {
        var account = CalendarAccount(
            displayName: "Work",
            serverURL: "owa.example.com",
            email: #"DOMAIN\user"#,
            accountType: .eas
        )
        account.easDevice = EASDeviceProfile(
            deviceType: "iPad",
            userAgent: "Apple-iPad/1234.56",
            model: "MX123LL/A",
            friendlyName: "Work iPad",
            osVersion: "iPadOS 18.0"
        )

        let restored = try decoder.decode(CalendarAccount.self, from: encoder.encode(account))
        XCTAssertEqual(restored.easDevice, account.easDevice)
        XCTAssertEqual(restored.resolvedDeviceProfile.deviceType, "iPad")
    }

    func testUnknownAccountTypeStillFailsLoudly() {
        // Not a regression guard but a boundary: a type this build does not know about is a
        // decode failure, not a silently dropped account.
        let future = """
        {"id":"6F24CAD5-99A5-4F1A-8902-46B8C68FAE8D","displayName":"X",
         "serverURL":"","email":"","accountType":"quantumCalendar"}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try decoder.decode(CalendarAccount.self, from: future))
    }

    // MARK: Device profile normalisation

    func testBlankFieldsFallBackToDefaults() {
        let blank = EASDeviceProfile(
            deviceType: "   ",
            userAgent: "",
            model: "\n",
            friendlyName: "",
            osVersion: " "
        )
        XCTAssertEqual(blank.normalized, EASDeviceProfile.default)
    }

    func testNormalisationTrimsWithoutReplacing() {
        let padded = EASDeviceProfile(deviceType: "  iPad  ", userAgent: " UA/1 ")
        let normalized = padded.normalized
        XCTAssertEqual(normalized.deviceType, "iPad")
        XCTAssertEqual(normalized.userAgent, "UA/1")
        XCTAssertEqual(normalized.model, EASDeviceProfile.default.model)
    }

    // MARK: Capability flags

    func testActiveSyncCapabilityFlags() {
        XCTAssertTrue(AccountType.eas.requiresPassword)
        XCTAssertTrue(AccountType.eas.usesDeviceProfile)
        XCTAssertFalse(AccountType.owa.usesDeviceProfile)

        // Both capabilities are built: ResolveRecipients answers free/busy, and a Sync Add
        // carrying an Attendees collection creates meetings. ActiveSync now matches OWA.
        XCTAssertTrue(AccountType.eas.supportsColleagueAvailability)
        XCTAssertTrue(AccountType.eas.supportsMeetingCreation)
    }

    func testGoogleCalendarDoesNotRequireAPasswordBeforeOAuthExists() {
        XCTAssertFalse(AccountType.googleCalendar.requiresPassword)
    }

    func testDefaultDeviceProfileIdentifiesTheAppHonestly() {
        XCTAssertEqual(EASDeviceProfile.default.deviceType, "OWAWidget")
        XCTAssertEqual(EASDeviceProfile.default.model, "Mac")
    }

    func testDeviceIdIsThirtyTwoHexCharacters() {
        let id = EASDeviceIdentity.generate()
        XCTAssertEqual(id.count, 32)
        XCTAssertTrue(id.allSatisfy { $0.isHexDigit && ($0.isNumber || $0.isUppercase) })
    }

    // MARK: Factory

    func testFactoryRefusesPasswordAccountsWithoutAPassword() {
        let account = CalendarAccount(
            displayName: "Work",
            serverURL: "owa.example.com",
            email: #"DOMAIN\user"#,
            accountType: .eas
        )
        XCTAssertThrowsError(try CalendarProviderFactory.make(account: account, password: nil)) { error in
            guard case CalendarProviderFactory.FactoryError.passwordRequired(.eas) = error else {
                return XCTFail("expected passwordRequired(.eas), got \(error)")
            }
        }
    }

    func testFactoryRejectsNonHTTPSServerURL() {
        let account = CalendarAccount(
            displayName: "Work",
            serverURL: "http://owa.example.com",
            email: #"DOMAIN\user"#,
            accountType: .eas
        )
        XCTAssertThrowsError(try CalendarProviderFactory.make(account: account, password: "pw"))
    }
}
