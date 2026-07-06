import XCTest
@testable import OWAWidget

/// Covers `OWAError.isSessionStaleHTTPError`, the discriminator that decides whether an HTTP
/// failure on a calendar request means "the session went stale, reachable server, re-auth and
/// retry" (401/440/449) versus anything else. The `449` case is the field regression: after OWA
/// moved to SSO, the front-end answers a request carrying a stale cookie with `449 "Retry With"`
/// instead of a clean `401`, so URLSession's NTLM delegate never fires and the app used to loop
/// `449` forever while mislabelling it "offline: showing cached".
final class OWASessionStaleClassificationTests: XCTestCase {

    // MARK: - Stale session → re-authenticate and retry

    func test401IsStaleSession() {
        XCTAssertTrue(OWAError.isSessionStaleHTTPError(OWAError.httpError(401, "")))
    }

    func test440IsStaleSession() {
        XCTAssertTrue(OWAError.isSessionStaleHTTPError(OWAError.httpError(440, "login timeout")))
    }

    func test449RetryWithIsStaleSession() {
        // The exact field case: Exchange front-end returns 449 with the generic IIS body when the
        // request rides a stale session cookie. Must trigger reauth, not an "offline" surface.
        let body = "The custom error module does not recognize this error."
        XCTAssertTrue(OWAError.isSessionStaleHTTPError(OWAError.httpError(449, body)))
    }

    // MARK: - Not a stale session

    func test404IsNotStaleSession() {
        // Off-VPN nginx 404: the request never reached Exchange. Re-authing would not help — it is a
        // connectivity condition the breaker rides out, not a session to refresh.
        let body = "<html><head><title>404 Not Found</title></head><body>nginx</body></html>"
        XCTAssertFalse(OWAError.isSessionStaleHTTPError(OWAError.httpError(404, body)))
    }

    func test500IsNotStaleSession() {
        XCTAssertFalse(OWAError.isSessionStaleHTTPError(OWAError.httpError(500, "server error")))
    }

    func testAuthenticationFailedIsNotStaleSession() {
        // A definitive credential rejection latches the wrong-password breaker; it is not the
        // reachable-but-stale case, so it must NOT be routed into the reauth-and-retry path.
        XCTAssertFalse(OWAError.isSessionStaleHTTPError(OWAError.authenticationFailed("bad creds")))
    }

    func testConnectivityURLErrorIsNotStaleSession() {
        XCTAssertFalse(OWAError.isSessionStaleHTTPError(URLError(.cannotConnectToHost)))
    }

    // MARK: - Kept distinct from the wrong-password latch

    func test449IsNotLatchedAsAuthError() {
        // Critical invariant: 449 must reauth-and-retry but must never latch the wrong-password
        // breaker (that would stop syncing and risk account lockout on a purely transient signal).
        let error = OWAError.httpError(449, "Retry With")
        XCTAssertTrue(OWAError.isSessionStaleHTTPError(error))
        XCTAssertFalse(OWAError.isAuthError(error))
        XCTAssertFalse(OWAError.isDefinitiveAuthRejection(error))
    }

    func test401StaleSessionIsAlsoAnAuthErrorForBreakerThreshold() {
        // 401/440 remain auth errors (ride the breaker threshold) as before — adding the stale-
        // session predicate must not change how the breaker already treats them.
        XCTAssertTrue(OWAError.isAuthError(OWAError.httpError(401, "")))
    }

    // MARK: - Raw-status helper used by the EWS on-demand paths

    func testStatusHelperMatchesTheThreeStaleCodes() {
        // The attendee / FindPeople / availability / CreateItem paths branch on the raw status code
        // before wrapping it in an OWAError; the helper must agree with the OWAError-based one.
        XCTAssertTrue(OWAError.isSessionStaleStatus(401))
        XCTAssertTrue(OWAError.isSessionStaleStatus(440))
        XCTAssertTrue(OWAError.isSessionStaleStatus(449))
    }

    func testStatusHelperRejectsOtherCodes() {
        for code in [200, 302, 403, 404, 500, 503] {
            XCTAssertFalse(OWAError.isSessionStaleStatus(code), "status \(code) must not be stale-session")
        }
    }
}
