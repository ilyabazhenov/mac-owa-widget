import XCTest
@testable import OWAWidget

/// Message bodies on a dark background: which ones may go dark, and how their colours change.
final class MailDarkModeTests: XCTestCase {
    private func dark(_ body: String) -> (html: String, isDark: Bool) {
        MailHTMLDocument.prepared(body: body, dark: true)
    }

    func testPlainMessageGoesDark() {
        let result = dark("<p>Hello</p>")
        XCTAssertTrue(result.isDark)
        XCTAssertTrue(result.html.contains(#"<meta name="color-scheme" content="dark">"#))
        XCTAssertTrue(result.html.contains("background: #1e1e20"))
        XCTAssertFalse(MailHTMLDocument.prepared(body: "<p>Hello</p>").isDark)
        XCTAssertTrue(MailHTMLDocument.prepared(body: "<p>Hello</p>").html.contains("background: #ffffff"))
    }

    func testOutlookReplyGoesDarkWithItsDarkTextMadeLight() {
        let body = """
        <html><head><style><!--
        p.MsoNormal {margin:0cm; font-size:11.0pt; color:black;}
        a:link {color:#0563C1; text-decoration:underline;}
        span.EmailStyle17 {color:windowtext}
        --></style></head>
        <body lang="RU" link="#0563C1" vlink="#954F72" style="background:white">
        <div><p class="MsoNormal"><span style="color:#1F497D">Signature</span></p>
        <table style="border:solid windowtext 1.0pt;background:#FFFFFF" bgcolor="white"><tr><td>x</td></tr></table>
        <font color="#000000">old</font></div></body></html>
        """
        let result = dark(body)
        XCTAssertTrue(result.isDark)
        let html = result.html
        XCTAssertTrue(html.contains("color:\(MailDarkMode.textColor);}"), "black in the style sheet")
        XCTAssertTrue(html.contains("{color:\(MailDarkMode.textColor)}"), "windowtext in the style sheet")
        XCTAssertFalse(html.contains("#0563C1"), "link colours made light")
        XCTAssertFalse(html.contains("#1F497D"))
        XCTAssertTrue(html.contains("border:solid \(MailDarkMode.textColor) 1.0pt;background:transparent"))
        XCTAssertFalse(html.contains("bgcolor"))
        XCTAssertTrue(html.contains(#"<font color="\#(MailDarkMode.textColor)">"#))
        XCTAssertTrue(html.contains("<!--"), "the style sheet keeps its comment")
    }

    func testMessageWithADesignStaysLight() {
        for body in [
            ##"<table bgcolor="#003366"><tr><td style="color:white">News</td></tr></table>"##,
            #"<div style="background-color: rgb(240, 120, 0)">Promo</div>"#,
            #"<td background="https://x/bg.png">x</td>"#,
            #"<div style="background:url(cid:abc) no-repeat">x</div>"#,
            "<style>.hero { background: #222 }</style><div class=hero>x</div>",
        ] {
            let result = dark(body)
            XCTAssertFalse(result.isDark, body)
            XCTAssertTrue(result.html.contains("background: #ffffff"), body)
        }
    }

    func testLightenedKeepsHueAndLeavesLightColoursAlone() {
        XCTAssertEqual(MailDarkMode.lightened("black"), MailDarkMode.textColor)
        XCTAssertEqual(MailDarkMode.lightened("#222"), MailDarkMode.textColor)
        XCTAssertNil(MailDarkMode.lightened("#ff0000"), "already light enough")
        XCTAssertNil(MailDarkMode.lightened("white"))
        XCTAssertNil(MailDarkMode.lightened("inherit"))
        let navy = try! XCTUnwrap(MailDarkMode.lightened("#1F497D").flatMap(MailDarkMode.parse))
        XCTAssertGreaterThan(navy.b, navy.r, "still blue")
        XCTAssertGreaterThan(navy.b, 0.6)
    }

    func testColourParsing() {
        XCTAssertEqual(MailDarkMode.parse("#FFF"), MailDarkMode.RGB(r: 1, g: 1, b: 1))
        XCTAssertEqual(MailDarkMode.parse("ffffff"), MailDarkMode.RGB(r: 1, g: 1, b: 1))
        XCTAssertEqual(MailDarkMode.parse("rgb(255, 0, 0)"), MailDarkMode.RGB(r: 1, g: 0, b: 0))
        XCTAssertEqual(MailDarkMode.parse("rgba(0,0,0,0)")?.alpha, 0)
        XCTAssertNil(MailDarkMode.parse("chartreuse-ish"))
        XCTAssertTrue(MailDarkMode.isLightBackground("transparent"))
        XCTAssertTrue(MailDarkMode.isLightBackground("#FAFAFA"))
        XCTAssertFalse(MailDarkMode.isLightBackground("#CCCCCC"))
        XCTAssertFalse(MailDarkMode.isLightBackground("papayawhip"), "unknown: kept light to be safe")
    }

    func testImportantIsKept() {
        let result = dark(#"<p style="color: #000 !important">x</p>"#)
        XCTAssertTrue(result.html.contains("color:\(MailDarkMode.textColor) !important"), result.html)
    }
}
