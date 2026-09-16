import XCTest
@testable import OWAWidget

/// Translating EAS failures into the vocabulary `CalendarService` reasons about.
///
/// This is where a mistake costs the most: an error that does not map lands in the generic
/// "offline" bucket, the sync status lies, and the authentication breaker — the thing standing
/// between a wrong password and an Active Directory lockout — never engages.
final class EASErrorBridgeTests: XCTestCase {

    private func bridged(_ error: Error) -> Error {
        EASErrorBridge.owaError(from: error, context: "test")
    }

    // MARK: The lockout guard

    /// Under Basic authentication a 401 is an answer, not a challenge. Mapping it to the
    /// *definitive* rejection latches the breaker on the first failure instead of riding the
    /// threshold — worth roughly four fewer password attempts per wrong password.
    func testAuthenticationRejectionIsDefinitive() {
        let mapped = bridged(EASError.authenticationRejected)
        XCTAssertTrue(OWAError.isAuthError(mapped))
        XCTAssertTrue(OWAError.isDefinitiveAuthRejection(mapped))
    }

    /// The password is fine; the mailbox is not enabled for ActiveSync. Latching the
    /// wrong-password breaker here would tell the user to re-enter a correct password.
    func testForbiddenDoesNotLatchTheBreaker() {
        let mapped = bridged(EASError.forbidden("ActiveSync may be disabled for this mailbox."))
        XCTAssertFalse(OWAError.isAuthError(mapped))
        XCTAssertFalse(OWAError.isDefinitiveAuthRejection(mapped))
    }

    func testServerErrorsDoNotLatchTheBreaker() {
        for error in [EASError.http(500, "x"), EASError.http(451, "moved"), EASError.protocolError("bad")] {
            XCTAssertFalse(OWAError.isDefinitiveAuthRejection(bridged(error)), "\(error)")
        }
    }

    /// Connectivity failures pass through untouched, so the service reads them as transient and
    /// falls back to the cached calendar — right when the network is down rather than the
    /// password wrong.
    func testTransportErrorsPassThroughUnchanged() {
        let offline = URLError(.notConnectedToInternet)
        let mapped = bridged(offline)
        XCTAssertEqual((mapped as? URLError)?.code, .notConnectedToInternet)
    }

    func testAlreadyBridgedErrorsAreNotWrappedTwice() {
        let already = OWAError.authenticationFailed("earlier")
        let mapped = bridged(already)
        XCTAssertTrue(OWAError.isDefinitiveAuthRejection(mapped))
    }

    // MARK: Status codes reaching the user

    /// The numeric code alone — "Exchange error: EASSyncStatus3" — is not something a person can
    /// act on. Both halves have to survive the translation: the code for a bug report, the
    /// sentence for whoever is looking at the popover.
    func testStatusExplanationSurvivesTheBridge() throws {
        let mapped = bridged(EASError.commandStatus(command: "Provision", status: "165"))
        let text = try XCTUnwrap((mapped as? LocalizedError)?.errorDescription)

        XCTAssertTrue(text.contains("165"), "the code stays lookup-able: \(text)")
        XCTAssertTrue(text.contains("DeviceInformation"), "and the reason is legible: \(text)")
    }

    func testDeviceBlockedIsLegible() throws {
        let mapped = bridged(EASError.commandStatus(command: "Sync", status: "177"))
        let text = try XCTUnwrap((mapped as? LocalizedError)?.errorDescription)
        XCTAssertTrue(text.contains("blocked"), text)
    }

    /// An unknown code has no sentence to add, and inventing one would be worse than the number.
    func testUnknownStatusStillCarriesTheNumber() throws {
        let mapped = bridged(EASError.commandStatus(command: "Sync", status: "9999"))
        let text = try XCTUnwrap((mapped as? LocalizedError)?.errorDescription)
        XCTAssertTrue(text.contains("9999"), text)
        XCTAssertTrue(text.contains("Sync"), text)
    }

    func testEveryExplainedStatusHasText() {
        for status in ["2", "3", "4", "5", "8", "12", "139", "142", "143", "144", "145", "165", "177"] {
            XCTAssertFalse(EASError.explain(status).isEmpty, "status \(status) has no explanation")
        }
    }
}
