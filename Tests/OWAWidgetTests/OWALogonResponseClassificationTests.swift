import XCTest
@testable import OWAWidget

/// Covers `OWAClient.responseLooksLikeOWALogon`, the discriminator that decides whether a
/// "no CANARY" authentication outcome is a genuine credential rejection (latch the wrong-password
/// breaker) or merely a connectivity detour — an external reverse-proxy 404 while VPN is off, a
/// 5xx, or a captive-portal/SSO page — that must NOT be mistaken for a bad password.
final class OWALogonResponseClassificationTests: XCTestCase {

    private func data(_ s: String) -> Data { Data(s.utf8) }

    // MARK: - Reached an OWA logon surface → bad credentials

    func testFinalURLOnLogonAspxIsLogon() {
        let url = URL(string: "https://owa.example.com/owa/auth/logon.aspx?replaceCurrent=1&reason=2")!
        XCTAssertTrue(OWAClient.responseLooksLikeOWALogon(finalURL: url, body: Data()))
    }

    func testFinalURLOnAuthOwaAloneIsNotLogon() {
        // `auth.owa` is the POST target, not evidence of a rendered logon page: a proxy can answer
        // it with a 404 (VPN off) without OWA ever responding. URL alone must NOT latch.
        let url = URL(string: "https://owa.example.com/owa/auth.owa")!
        XCTAssertFalse(OWAClient.responseLooksLikeOWALogon(finalURL: url, body: Data()))
    }

    func testRealisticOWALogonBodyIsLogon() {
        // A real OWA forms-logon page carries the `auth_logon` ASP-page marker and posts to
        // auth.owa with a `passwd` field.
        let html = """
        <html><head><!-- OwaPage = ASP.auth_logon_aspx --></head><body>
        <form action="/owa/auth.owa" method="POST" name="logonForm">
        <input type="text" name="username">
        <input type="password" name="passwd">
        </form></body></html>
        """
        XCTAssertTrue(OWAClient.responseLooksLikeOWALogon(finalURL: nil, body: data(html)))
    }

    func testWindows1251EncodedLogonBodyIsRecognised() {
        // RU Exchange may serve logon.aspx as windows-1251; the ASCII markers must still be found
        // even when surrounding bytes are not valid UTF-8 (regression guard for the body decode).
        var bytes = Data([0xCF, 0xE0, 0xF0, 0xEE, 0xEB, 0xFC]) // "Пароль" in cp1251 — invalid UTF-8
        bytes.append(Data("<!-- OwaPage = ASP.auth_logon_aspx -->".utf8))
        XCTAssertNil(String(data: bytes, encoding: .utf8), "Precondition: body is not valid UTF-8")
        XCTAssertTrue(OWAClient.responseLooksLikeOWALogon(finalURL: nil, body: bytes))
    }

    func testBodyWithLogonFormFieldsButNoMarkerURLIsLogon() {
        // Form posts to an absolute action on another path, but carries OWA's signature
        // hidden field + password field.
        let html = """
        <html><body><form method="POST">
        <input type="hidden" name="destination" value="https://owa.example.com/owa/">
        <input type="hidden" name="flags" value="4">
        <input type="password" name="passwd">
        </form></body></html>
        """
        XCTAssertTrue(OWAClient.responseLooksLikeOWALogon(finalURL: nil, body: data(html)))
    }

    func testBadPasswordResponseWithNon2xxStatusStillRecognisedByBody() {
        // Some deployments serve the re-rendered logon page with a non-2xx status; content, not
        // status, decides — recognised here by the OWA `auth_logon` page marker.
        let html = "<html><head><!-- OwaPage = ASP.auth_logon_aspx --></head><body><form action=\"https://owa.example.com/owa/auth.owa\"></form></body></html>"
        XCTAssertTrue(OWAClient.responseLooksLikeOWALogon(finalURL: nil, body: data(html)))
    }

    // MARK: - Never reached OWA → connectivity, not credentials

    func testNginx404OnAuthOwaPathIsNotLogon() {
        // The exact off-VPN case observed in the field: external nginx answers /owa/auth.owa with
        // a 404. Final url is still auth.owa (no redirect), body is the nginx error page — neither
        // carries an OWA logon marker, so this must be classified as connectivity, not bad creds.
        let html = "<html>\n<head><title>404 Not Found</title></head>\n<body>\n<center><h1>404 Not Found</h1></center>\n<hr><center>nginx</center>\n</body>\n</html>"
        let url = URL(string: "https://owa.example.com/owa/auth.owa")!
        XCTAssertFalse(OWAClient.responseLooksLikeOWALogon(finalURL: url, body: data(html)))
    }

    func testCaptivePortal200PageIsNotLogon() {
        let html = """
        <html><body><h1>Sign in to Wi-Fi</h1>
        <form action="https://portal.wifi.example/login" method="POST">
        <input type="text" name="email">
        <input type="password" name="password">
        </form></body></html>
        """
        let url = URL(string: "https://portal.wifi.example/login")!
        XCTAssertFalse(OWAClient.responseLooksLikeOWALogon(finalURL: url, body: data(html)))
    }

    func testGenericPasswordFormWithoutOWAFieldsIsNotLogon() {
        // A lone password field (no OWA hidden fields, no marker URL) must not be attributed to OWA.
        let html = "<html><body><form><input type=\"password\" name=\"password\"></form></body></html>"
        XCTAssertFalse(OWAClient.responseLooksLikeOWALogon(finalURL: nil, body: data(html)))
    }

    func testProxyEchoingAuthOwaPathInBodyIsNotLogon() {
        // A proxy/SSO error page that merely echoes the requested `/owa/auth.owa` path must NOT be
        // mistaken for an OWA logon page — it has no auth_logon / logon.aspx / OWA-form markers.
        let html = "<html><body><h1>403 Forbidden</h1><p>Requested URL: /owa/auth.owa was blocked.</p></body></html>"
        let url = URL(string: "https://owa.example.com/owa/auth.owa")!
        XCTAssertFalse(OWAClient.responseLooksLikeOWALogon(finalURL: url, body: data(html)))
    }

    func testEmptyBodyAndNilURLIsNotLogon() {
        XCTAssertFalse(OWAClient.responseLooksLikeOWALogon(finalURL: nil, body: Data()))
    }

    func testServiceUnavailableBodyIsNotLogon() {
        let html = "<html><head><title>503 Service Unavailable</title></head><body>Service Unavailable</body></html>"
        let url = URL(string: "https://owa.example.com/owa/")!
        XCTAssertFalse(OWAClient.responseLooksLikeOWALogon(finalURL: url, body: data(html)))
    }

    func testNonUTF8BinaryBodyIsNotLogon() {
        let bytes = Data([0xFF, 0xFE, 0x00, 0x01, 0x80, 0x90])
        XCTAssertFalse(OWAClient.responseLooksLikeOWALogon(finalURL: nil, body: bytes))
    }
}
