import XCTest
@testable import OWAWidget

/// The formatted text model and the HTML it goes to Exchange as.
final class RichTextHTMLTests: XCTestCase {
    private typealias Block = RichText.Block
    private typealias Run = RichText.Run

    private func item(_ text: String, _ list: RichText.ListKind...) -> Block {
        Block(runs: [Run(text: text)], list: list)
    }

    private func paragraph(_ text: String) -> Block {
        Block(runs: [Run(text: text)])
    }

    func testPlainTextIsOneParagraphPerLine() {
        XCTAssertEqual(RichTextHTML.fragment("a\n\nb"), "<div>a</div><div><br></div><div>b</div>")
        XCTAssertEqual(RichText(plain: "a\r\nb").blocks.count, 2)
        XCTAssertEqual(RichText(plain: "a\nb").plainText, "a\nb")
    }

    func testEverythingTypedIsEscaped() {
        let html = RichTextHTML.fragment("<script>alert(\"x\")</script> & ]]>")
        XCTAssertEqual(html, "<div>&lt;script&gt;alert(&quot;x&quot;)&lt;/script&gt; &amp; ]]&gt;</div>")
    }

    func testStylesNestInAFixedOrder() {
        let text = RichText(blocks: [Block(runs: [
            Run(text: "a", style: [.bold, .italic, .underline, .strikethrough]),
            Run(text: "b"),
            Run(text: "c", style: .bold),
        ])])
        XCTAssertEqual(RichTextHTML.fragment(text), "<div><b><i><u><s>a</s></u></i></b>b<b>c</b></div>")
    }

    func testRunsThatLookTheSameAreMerged() {
        let text = RichText(blocks: [Block(runs: [Run(text: "a", style: .bold), Run(text: ""), Run(text: "b", style: .bold)])])
        XCTAssertEqual(text.blocks[0].runs, [Run(text: "ab", style: .bold)])
    }

    func testOnlyWebAndMailLinksAreSent() {
        let text = RichText(blocks: [Block(runs: [
            Run(text: "site", link: URL(string: "https://example.com/?a=1&b=%222%22")),
            Run(text: " js", link: URL(string: "javascript:alert(1)")),
            Run(text: " file", link: URL(string: "file:///etc/passwd")),
            Run(text: " mail", style: .bold, link: URL(string: "mailto:a@b.c")),
        ])])
        XCTAssertEqual(
            RichTextHTML.fragment(text),
            #"<div><a href="https://example.com/?a=1&amp;b=%222%22">site</a> js file<a href="mailto:a@b.c"><b> mail</b></a></div>"#
        )
    }

    func testFlatLists() {
        let text = RichText(blocks: [item("a", .bullet), item("b", .bullet), paragraph("p"), item("1", .numbered), item("2", .numbered)])
        XCTAssertEqual(
            RichTextHTML.fragment(text),
            "<ul style=\"margin-top: 0; margin-bottom: 0;\"><li>a</li><li>b</li></ul><div>p</div>"
                + "<ol style=\"margin-top: 0; margin-bottom: 0;\"><li>1</li><li>2</li></ol>"
        )
    }

    func testNestedListsSitInTheirParentItem() {
        let text = RichText(blocks: [
            item("a", .bullet),
            item("a1", .bullet, .numbered),
            item("a2", .bullet, .numbered),
            item("b", .bullet),
        ])
        let ul = "<ul style=\"margin-top: 0; margin-bottom: 0;\">"
        let ol = "<ol style=\"margin-top: 0; margin-bottom: 0;\">"
        XCTAssertEqual(RichTextHTML.fragment(text), "\(ul)<li>a\(ol)<li>a1</li><li>a2</li></ol></li><li>b</li></ul>")
    }

    func testAListOfAnotherKindIsAnotherList() {
        let text = RichText(blocks: [item("a", .bullet), item("1", .numbered)])
        let html = RichTextHTML.fragment(text)
        XCTAssertTrue(html.contains("<li>a</li></ul><ol"), html)
    }

    func testAnItemThatStartsDeeperHangsInAnUnmarkedParent() {
        let text = RichText(blocks: [item("deep", .bullet, .bullet)])
        let ul = "<ul style=\"margin-top: 0; margin-bottom: 0;\">"
        XCTAssertEqual(RichTextHTML.fragment(text), "\(ul)<li style=\"list-style: none;\">\(ul)<li>deep</li></ul></li></ul>")
    }

    func testEmptyItemsAndParagraphsKeepTheirLine() {
        let text = RichText(blocks: [item("", .bullet), paragraph("")])
        XCTAssertEqual(RichTextHTML.fragment(text), "<ul style=\"margin-top: 0; margin-bottom: 0;\"><li><br></li></ul><div><br></div>")
    }

    func testListsAreNoDeeperThanAllowed() {
        let text = RichText(blocks: [Block(runs: [Run(text: "x")], list: Array(repeating: .bullet, count: 9))])
        XCTAssertEqual(text.blocks[0].list.count, RichText.maxListDepth)
    }

    func testMarkersNumberEachListAndStartOverAfterAParagraph() {
        let text = RichText(blocks: [
            item("a", .numbered),
            item("a.a", .numbered, .numbered),
            item("a.b", .numbered, .numbered),
            item("b", .numbered),
            item("b.a", .numbered, .numbered),
            item("dot", .numbered, .bullet),
            paragraph("p"),
            item("again", .numbered),
        ])
        XCTAssertEqual(text.listMarkers, ["1.", "1.", "2.", "2.", "1.", "•", nil, "1."])
        XCTAssertEqual(text.plainText, "1. a\n    1. a.a\n    2. a.b\n2. b\n    1. b.a\n    • dot\np\n1. again")
    }

    func testTrimmedDropsBlankLinesAtTheEnds() {
        let text = RichText(plain: "\n  \n  Goals  \n\n")
        XCTAssertEqual(text.trimmed(), RichText(plain: "Goals"))
        XCTAssertTrue(RichText(plain: " \n ").isBlank)
        XCTAssertFalse(RichText(blocks: [item("", .bullet)]).isBlank)
    }

    func testMailBodyWrapsTheFragmentInItsFont() {
        let html = OWAMailPayloads.outgoingBodyHTML(RichText(blocks: [item("x", .bullet)]))
        XCTAssertTrue(html.contains("font-size: 11pt;\"><ul style"), html)
    }

    func testMeetingBodyCarriesTheFormatting() {
        let agenda = RichText(blocks: [paragraph(""), Block(runs: [Run(text: "Goals", style: .bold)]), item("one", .numbered), paragraph(" ")])
        let soap = OWACreateCalendarEventPayload.createItemSOAP(
            title: "T", agenda: agenda, location: "", start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 1800),
            requiredAttendees: []
        )
        XCTAssertTrue(soap.contains("<body dir=\"ltr\"><div><b>Goals</b></div><ol style=\"margin-top: 0; margin-bottom: 0;\"><li>one</li></ol></body>"), soap)
        let blank = OWACreateCalendarEventPayload.createItemSOAP(
            title: "T", agenda: "  \n ", location: "", start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 1800),
            requiredAttendees: []
        )
        XCTAssertFalse(blank.contains("<t:Body"))
    }
}
