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

// MARK: - Credential host binding

/// Credentials must reach the account's own server and nothing else, however the request got
/// there. Redirects are followed across hosts on purpose, and the session delegate answers auth
/// challenges for whatever host the request lands on — so the host check is the only thing
/// standing between a hostile redirect and the domain account's NTLMv2 response.
final class CredentialHostPolicyTests: XCTestCase {

    func testConfiguredHostIsAllowed() {
        XCTAssertTrue(OWACredentialHostPolicy.allowsCredentials(
            challengeHost: "mail.example.com",
            configuredHost: "mail.example.com"
        ))
    }

    func testHostMatchIsCaseInsensitive() {
        XCTAssertTrue(OWACredentialHostPolicy.allowsCredentials(
            challengeHost: "MAIL.Example.COM",
            configuredHost: "mail.example.com"
        ))
    }

    func testTrailingRootLabelIsTheSameHost() {
        XCTAssertTrue(OWACredentialHostPolicy.allowsCredentials(
            challengeHost: "mail.example.com.",
            configuredHost: "mail.example.com"
        ))
    }

    func testForeignHostIsRefused() {
        XCTAssertFalse(OWACredentialHostPolicy.allowsCredentials(
            challengeHost: "evil.test",
            configuredHost: "mail.example.com"
        ))
    }

    /// The attack a suffix rule would let through.
    func testSuffixLookalikeIsRefused() {
        XCTAssertFalse(OWACredentialHostPolicy.allowsCredentials(
            challengeHost: "mail.example.com.evil.test",
            configuredHost: "mail.example.com"
        ))
    }

    /// Sibling hosts are not requested by this client, so they get no credentials either.
    func testSubdomainIsRefused() {
        XCTAssertFalse(OWACredentialHostPolicy.allowsCredentials(
            challengeHost: "autodiscover.mail.example.com",
            configuredHost: "mail.example.com"
        ))
        XCTAssertFalse(OWACredentialHostPolicy.allowsCredentials(
            challengeHost: "mail.example.com",
            configuredHost: "example.com"
        ))
    }

    /// Fails closed: an empty configured host must not match an empty challenge host.
    func testEmptyConfiguredHostRefusesEveryone() {
        XCTAssertFalse(OWACredentialHostPolicy.allowsCredentials(challengeHost: "", configuredHost: ""))
        XCTAssertFalse(OWACredentialHostPolicy.allowsCredentials(
            challengeHost: "mail.example.com",
            configuredHost: ""
        ))
    }

    func testCredentialBearingMethodsAreGuarded() {
        for method in [
            NSURLAuthenticationMethodNTLM,
            NSURLAuthenticationMethodNegotiate,
            NSURLAuthenticationMethodHTTPBasic,
            NSURLAuthenticationMethodHTTPDigest,
            NSURLAuthenticationMethodHTMLForm
        ] {
            XCTAssertTrue(OWACredentialHostPolicy.carriesCredentials(method), method)
        }
    }

    /// TLS evaluation has to run for every host the request reaches; the pin store is keyed by
    /// host, so it stays correct on its own.
    func testServerTrustIsNotGuarded() {
        XCTAssertFalse(OWACredentialHostPolicy.carriesCredentials(NSURLAuthenticationMethodServerTrust))
        XCTAssertFalse(OWACredentialHostPolicy.carriesCredentials(NSURLAuthenticationMethodClientCertificate))
    }
}

// MARK: - EWS respond payload escaping

/// `itemId` and `changeKey` come out of the server's own JSON. Unescaped, a `"` in either one
/// closes the attribute and lets the response envelope carry whatever the server wants.
final class RespondToMeetingPayloadTests: XCTestCase {

    func testItemIdIsXMLEscaped() {
        let soap = OWARespondToMeetingPayload.soap(
            itemId: #"AAA"/><t:Evil x=""#,
            changeKey: "CQ",
            action: .accept
        )
        XCTAssertFalse(soap.contains("<t:Evil"))
        XCTAssertTrue(soap.contains("&quot;"))
        XCTAssertTrue(soap.contains("&lt;t:Evil"))
    }

    func testChangeKeyIsXMLEscaped() {
        let soap = OWARespondToMeetingPayload.soap(
            itemId: "AAA",
            changeKey: #"CQ"/><t:Evil/><t:X y=""#,
            action: .decline
        )
        XCTAssertFalse(soap.contains("<t:Evil/>"))
        XCTAssertTrue(soap.contains("&lt;t:Evil/&gt;"))
    }

    func testAmpersandIsEscaped() {
        let soap = OWARespondToMeetingPayload.soap(itemId: "A&B", changeKey: "C&D", action: .tentative)
        XCTAssertTrue(soap.contains(#"Id="A&amp;B""#))
        XCTAssertTrue(soap.contains(#"ChangeKey="C&amp;D""#))
    }

    func testOrdinaryIdentifiersSurviveUnchanged() {
        let soap = OWARespondToMeetingPayload.soap(
            itemId: "AAMkAGI1+/9j=",
            changeKey: "DwAAABYAAAA=",
            action: .accept
        )
        XCTAssertTrue(soap.contains(#"<t:ReferenceItemId Id="AAMkAGI1+/9j=" ChangeKey="DwAAABYAAAA="/>"#))
        XCTAssertTrue(soap.contains("<t:AcceptItem>"))
    }

    func testElementNamePerAction() {
        XCTAssertEqual(OWARespondToMeetingPayload.elementName(for: .accept), "AcceptItem")
        XCTAssertEqual(OWARespondToMeetingPayload.elementName(for: .tentative), "TentativelyAcceptItem")
        XCTAssertEqual(OWARespondToMeetingPayload.elementName(for: .decline), "DeclineItem")
    }
}

// MARK: - HTTP error descriptions

/// `OWAError.httpError` is logged at `.public` on the sync paths and shown in the popover status
/// line, so its description must carry the shape of a failure and never its content.
final class HTTPErrorDescriptionTests: XCTestCase {

    func testHTMLBodyIsNotEchoed() {
        let page = "<html><body>SAMLResponse=PHNhbWxwOlJlc3BvbnNlIElE and a mailbox address</body></html>"
        let description = OWAError.httpError(500, page).localizedDescription
        XCTAssertFalse(description.contains("SAMLResponse"))
        XCTAssertFalse(description.contains("mailbox address"))
        XCTAssertTrue(description.contains("500"))
        XCTAssertTrue(description.contains("html"))
    }

    func testPlainBodyIsNotEchoed() {
        let description = OWAError.httpError(502, "upstream connect error to 10.1.2.3:443").localizedDescription
        XCTAssertFalse(description.contains("10.1.2.3"))
        XCTAssertTrue(description.contains("502"))
    }

    /// The one thing worth keeping: Exchange's own bounded fault string, which is what makes a 500
    /// diagnosable without a debug build.
    func testExchangeFaultMessageIsKept() {
        let body = #"{"Body":{"FaultMessage":"Cannot create an abstract class."}}"#
        let description = OWAError.httpError(500, body).localizedDescription
        XCTAssertTrue(description.contains("Cannot create an abstract class."))
    }

    func testEmptyBodyStaysBare() {
        XCTAssertEqual(OWAError.httpError(404, "").localizedDescription, "HTTP 404")
    }
}
