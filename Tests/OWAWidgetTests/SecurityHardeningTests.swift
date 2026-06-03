import XCTest
@testable import OWAWidget

/// Regression tests for the security-hardening changes:
/// - meeting-URL scheme validation/normalization (MeetingURLOpener)
/// - HTTPS enforcement for server URLs (OWAClient.parseBaseURL)
final class SecurityHardeningTests: XCTestCase {

    // MARK: - MeetingURLOpener.safeURL

    func testHTTPSURLPassesThrough() {
        let url = URL(string: "https://teams.microsoft.com/l/meetup-join/abc")!
        XCTAssertEqual(MeetingURLOpener.safeURL(from: url)?.absoluteString,
                       "https://teams.microsoft.com/l/meetup-join/abc")
    }

    func testHTTPIsUpgradedToHTTPS() {
        let url = URL(string: "http://acme.ktalk.ru/room/1")!
        XCTAssertEqual(MeetingURLOpener.safeURL(from: url)?.scheme, "https")
    }

    func testSchemelessURLIsNormalizedToHTTPS() {
        let resolved = MeetingURLOpener.safeURL(fromString: "teams.microsoft.com/l/meetup-join/abc")
        XCTAssertEqual(resolved?.scheme, "https")
        XCTAssertEqual(resolved?.host, "teams.microsoft.com")
    }

    func testFileSchemeIsRejected() {
        let url = URL(string: "file:///etc/passwd")!
        XCTAssertNil(MeetingURLOpener.safeURL(from: url))
    }

    func testCustomAppSchemeIsRejected() {
        let url = URL(string: "msteams://teams.microsoft.com/l/meetup-join/abc")!
        XCTAssertNil(MeetingURLOpener.safeURL(from: url))
    }

    func testPathOnlyStringIsRejected() {
        // No host once normalized → not openable.
        XCTAssertNil(MeetingURLOpener.safeURL(fromString: "/etc/passwd"))
    }

    // MARK: - OWAClient.parseBaseURL HTTPS enforcement

    func testBareHostDefaultsToHTTPS() throws {
        let url = try OWAClient.parseBaseURL("mail.example.com")
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "mail.example.com")
    }

    func testExplicitHTTPSIsAccepted() throws {
        let url = try OWAClient.parseBaseURL("https://mail.example.com")
        XCTAssertEqual(url.scheme, "https")
    }

    func testExplicitHTTPIsRejected() {
        XCTAssertThrowsError(try OWAClient.parseBaseURL("http://mail.example.com"))
    }
}
