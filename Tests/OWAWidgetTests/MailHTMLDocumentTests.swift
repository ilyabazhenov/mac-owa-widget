import XCTest
@testable import OWAWidget

final class MailHTMLDocumentTests: XCTestCase {
    func testDocumentCarriesStrictCSP() {
        let doc = MailHTMLDocument.document(body: "<p>Hi</p>")
        XCTAssertTrue(doc.contains("Content-Security-Policy"))
        XCTAssertTrue(doc.contains("default-src 'none'; img-src data:"))
        XCTAssertTrue(doc.contains("<body><div id=\"owaw-root\"><p>Hi</p></div></body>"))
    }

    func testSanitizerDropsActiveContent() {
        let html = """
        <p onclick="steal()">x</p><script>alert(1)</script><iframe src="https://evil.example"></iframe>
        <meta http-equiv="refresh" content="0;url=https://evil.example"><base href="https://evil.example/">
        <link rel="stylesheet" href="https://evil.example/a.css"><a href="javascript:alert(1)">y</a>
        <form action="https://evil.example"><input name="p"></form><img src="x" onerror='go()'>
        """
        let clean = MailHTMLDocument.sanitized(html)
        for needle in ["<script", "alert(1)</script>", "<iframe", "<meta", "<base", "<link", "onclick", "onerror", "javascript:", "<form", "<input"] {
            XCTAssertFalse(clean.lowercased().contains(needle.lowercased()), needle)
        }
        XCTAssertTrue(clean.contains("<p>x</p>"))
    }

    func testCIDImagesBecomeDataURIs() {
        let body = #"<img src="cid:image003.png@01DD" width="10"><img src="https://tracker.example/p.gif">"#
        let doc = MailHTMLDocument.document(body: body, inlineImages: ["image003.png@01DD": (Data([1, 2, 3]), "image/png")])
        XCTAssertTrue(doc.contains(#"<img src="data:image/png;base64,AQID" width="10">"#))
        XCTAssertTrue(doc.contains("https://tracker.example/p.gif"), "left for the CSP to block")
        XCTAssertEqual(MailHTMLDocument.remoteImageSources(in: body), ["https://tracker.example/p.gif"])
    }

    func testRemoteImagesLoadedByChoice() {
        let body = #"<img src='https://cdn.example/logo.png?a=1&amp;b=2'>"#
        let doc = MailHTMLDocument.document(body: body, remoteImages: ["https://cdn.example/logo.png?a=1&b=2": (Data([9]), "image/png")])
        XCTAssertTrue(doc.contains("<img src='data:image/png;base64,CQ=='>"))
    }

    func testDataURIRejectsOddTypes() {
        XCTAssertEqual(MailHTMLDocument.dataURI(Data([0]), type: "image/png\"><script>"), "data:application/octet-stream;base64,AA==")
    }

    func testMismatchedLinkHost() {
        let url = URL(string: "https://login.evil.example/bank")!
        XCTAssertEqual(MailHTMLDocument.mismatchedLinkHost(text: "www.bank.com", url: url), "www.bank.com")
        XCTAssertNil(MailHTMLDocument.mismatchedLinkHost(text: "Click here", url: url))
        XCTAssertNil(MailHTMLDocument.mismatchedLinkHost(text: "https://evil.example", url: url))
        XCTAssertNil(MailHTMLDocument.mismatchedLinkHost(text: "www.example.com", url: URL(string: "https://example.com/x")!))
    }

    func testPlainText() {
        XCTAssertEqual(MailHTMLDocument.plainText("<div>Hello<br>world</div><script>x()</script>"), "Hello\nworld")
        XCTAssertEqual(MailHTMLDocument.plainText(nil), "")
    }

    func testVisuallyEmptyBodies() {
        XCTAssertTrue(MailHTMLDocument.isVisuallyEmpty(nil))
        XCTAssertTrue(MailHTMLDocument.isVisuallyEmpty("<html><body><div>&nbsp;</div>\n<div style=\"\">&nbsp;</div></body></html>"))
        XCTAssertTrue(MailHTMLDocument.isVisuallyEmpty("<p>\u{200B}</p><br>"))
        XCTAssertFalse(MailHTMLDocument.isVisuallyEmpty("<p>Agenda</p>"))
        XCTAssertFalse(MailHTMLDocument.isVisuallyEmpty(#"<img src="cid:logo">"#))
    }

    func testListsKeepRoomForBullets() {
        XCTAssertTrue(MailHTMLDocument.document(body: "<ul><li>x</li></ul>").contains("padding-inline-start: 1.6em !important"))
    }
}

import WebKit

@MainActor
final class MailContentBlockerTests: XCTestCase {
    /// A rule WebKit cannot parse fails the whole list, and the reader then runs without it.
    func testBlockingRulesCompile() async throws {
        let store = try XCTUnwrap(WKContentRuleListStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("owaw-rules-\(UUID().uuidString)")))
        let list = try await store.compileContentRuleList(forIdentifier: "test", encodedContentRuleList: MailContentBlocker.rules)
        XCTAssertNotNil(list)
    }
}
