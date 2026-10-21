import AppKit
import XCTest
@testable import OWAWidget

/// The editor's lists and styles: markers kept right as the text changes, and what comes out.
@MainActor
final class RichTextEditorTests: XCTestCase {
    private func makeView(_ text: RichText = .empty) -> RichTextView {
        let view = RichTextView(usingTextLayoutManager: false)
        view.isRichText = true
        view.baseFont = RichTextEditor.font
        view.textStorage?.setAttributedString(RichTextAttributed.attributedString(text, images: [], base: view.baseFont))
        view.typingAttributes = view.baseAttributes
        return view
    }

    private func content(_ view: RichTextView) -> RichText {
        RichTextAttributed.richText(from: view.textStorage!).text
    }

    private func type(_ text: String, into view: RichTextView) {
        for character in text {
            if character == "\n" {
                view.insertNewline(nil)
            } else {
                view.insertText(String(character), replacementRange: view.selectedRange())
            }
        }
    }

    private func moveToEnd(_ view: RichTextView) {
        view.setSelectedRange(NSRange(location: view.textStorage!.length, length: 0))
    }

    func testMarkersAreTextButNotContent() {
        let text = RichText(blocks: [
            RichText.Block(runs: [RichText.Run(text: "one")], list: [.numbered]),
            RichText.Block(runs: [RichText.Run(text: "two", style: .bold)], list: [.numbered, .bullet]),
        ])
        let attributed = RichTextAttributed.attributedString(text, images: [], base: RichTextEditor.font)
        XCTAssertEqual(attributed.string, "\t1.\tone\n\t•\ttwo")
        XCTAssertEqual(RichTextAttributed.richText(from: attributed).text, text)
    }

    func testListButtonMakesItemsAndTakesThemBack() {
        let view = makeView("a\nb")
        view.setSelectedRange(NSRange(location: 0, length: 3))
        view.toggleList(.bullet)
        XCTAssertEqual(view.string, "\t•\ta\n\t•\tb")
        XCTAssertEqual(content(view).blocks.map(\.list), [[.bullet], [.bullet]])
        view.toggleList(.numbered)
        XCTAssertEqual(view.string, "\t1.\ta\n\t2.\tb")
        view.setSelectedRange(NSRange(location: 0, length: view.string.count))
        view.toggleList(.numbered)
        XCTAssertEqual(view.string, "a\nb")
    }

    func testReturnContinuesTheListAndAnEmptyItemEndsIt() {
        let view = makeView()
        type("1. first\nsecond\n\nafter", into: view)
        XCTAssertEqual(view.string, "\t1.\tfirst\n\t2.\tsecond\nafter")
        XCTAssertEqual(content(view).plainText, "1. first\n2. second\nafter")
    }

    func testDashStartsABulletedList() {
        let view = makeView()
        type("- milk\n* eggs", into: view)
        XCTAssertEqual(view.string, "\t•\tmilk\n\t•\t* eggs")
        let other = makeView("x")
        moveToEnd(other)
        type(" - not a list", into: other)
        XCTAssertEqual(other.string, "x - not a list")
    }

    func testTabNestsAndBacktabLifts() {
        let view = makeView()
        type("1. a\nb", into: view)
        view.insertTab(nil)
        XCTAssertEqual(view.string, "\t1.\ta\n\t1.\tb")
        XCTAssertEqual(content(view).blocks.map(\.list), [[.numbered], [.numbered, .numbered]])
        type("\nc", into: view)
        XCTAssertEqual(view.string, "\t1.\ta\n\t1.\tb\n\t2.\tc")
        view.insertBacktab(nil)
        XCTAssertEqual(view.string, "\t1.\ta\n\t1.\tb\n\t2.\tc")
        XCTAssertEqual(content(view).blocks.map(\.list.count), [1, 2, 1])
    }

    func testTabOutsideAListIsATab() {
        let view = makeView("a")
        moveToEnd(view)
        view.insertTab(nil)
        XCTAssertEqual(view.string, "a\t")
    }

    func testBackspaceAfterTheMarkerLiftsTheItem() {
        let view = makeView()
        type("- a\n", into: view)
        view.insertTab(nil)
        XCTAssertEqual(content(view).blocks.last?.list, [.bullet, .bullet])
        view.deleteBackward(nil)
        XCTAssertEqual(content(view).blocks.last?.list, [.bullet])
        view.deleteBackward(nil)
        XCTAssertEqual(view.string, "\t•\ta\n")
        XCTAssertEqual(content(view).blocks.map(\.list), [[.bullet], []])
    }

    func testDeletingAnItemRenumbersTheRest() {
        let view = makeView(RichText(blocks: ["a", "b", "c"].map { RichText.Block(runs: [RichText.Run(text: $0)], list: [.numbered]) }))
        // The line break and the second marker: joining the lines leaves the first marker.
        view.setSelectedRange(NSRange(location: 5, length: 5))
        view.deleteBackward(nil)
        XCTAssertEqual(view.string, "\t1.\tab\n\t2.\tc")
    }

    func testTheCaretStaysOutOfMarkers() {
        let view = makeView(RichText(blocks: [RichText.Block(runs: [RichText.Run(text: "a")], list: [.bullet])]))
        view.setSelectedRange(NSRange(location: 1, length: 0))
        XCTAssertEqual(view.selectedRange().location, 3)
        type("x", into: view)
        XCTAssertEqual(content(view).blocks[0].text, "xa")
    }

    func testBoldTogglesOnTheSelectionAndForTyping() {
        let view = makeView("hello world")
        view.setSelectedRange(NSRange(location: 0, length: 5))
        view.toggle(.bold)
        XCTAssertEqual(content(view).blocks[0].runs, [RichText.Run(text: "hello", style: .bold), RichText.Run(text: " world")])
        XCTAssertTrue(view.formatState.style.contains(.bold))
        view.toggle(.bold)
        XCTAssertEqual(content(view).blocks[0].runs, [RichText.Run(text: "hello world")])

        moveToEnd(view)
        view.toggle(.italic)
        type("!", into: view)
        XCTAssertEqual(content(view).blocks[0].runs.last, RichText.Run(text: "!", style: .italic))
    }

    func testLinkGoesOnTheSelectionOrIsTyped() {
        let view = makeView("see docs")
        view.setLink(URL(string: "https://example.com"), in: NSRange(location: 4, length: 4))
        XCTAssertEqual(content(view).blocks[0].runs.last, RichText.Run(text: "docs", link: URL(string: "https://example.com")))
        view.setLink(nil, in: NSRange(location: 4, length: 4))
        XCTAssertEqual(content(view).blocks[0].runs, [RichText.Run(text: "see docs")])

        moveToEnd(view)
        view.setLink(URL(string: "mailto:a@b.ru"), in: view.selectedRange())
        XCTAssertEqual(content(view).blocks[0].runs.last, RichText.Run(text: "a@b.ru", link: URL(string: "mailto:a@b.ru")))
        view.setLink(URL(string: "javascript:alert(1)"), in: NSRange(location: 0, length: 3))
        XCTAssertNil(content(view).blocks[0].runs.first?.link)
    }

    func testLinkAddressesAsTyped() {
        XCTAssertEqual(RichTextEditorController.linkURL(from: "example.com/a"), URL(string: "https://example.com/a"))
        XCTAssertEqual(RichTextEditorController.linkURL(from: " name@corp.ru "), URL(string: "mailto:name@corp.ru"))
        XCTAssertEqual(RichTextEditorController.linkURL(from: "http://x.ru"), URL(string: "http://x.ru"))
        XCTAssertNil(RichTextEditorController.linkURL(from: "javascript:alert(1)"))
        XCTAssertNil(RichTextEditorController.linkURL(from: "two words"))
        XCTAssertNil(RichTextEditorController.linkURL(from: "word"))
    }

    func testPastedListFromAnotherAppKeepsItsLevels() {
        // How TextEdit writes a list: the marker is plain text, the lists are in the style.
        let outer = NSTextList(markerFormat: .disc, options: 0)
        let inner = NSTextList(markerFormat: .decimal, options: 0)
        let first = NSMutableParagraphStyle()
        first.textLists = [outer]
        let second = NSMutableParagraphStyle()
        second.textLists = [outer, inner]
        let source = NSMutableAttributedString(string: "\t•\tTop\n", attributes: [.paragraphStyle: first, .font: NSFont(name: "Helvetica-Bold", size: 18)!])
        source.append(NSAttributedString(string: "\t1.\tNested", attributes: [.paragraphStyle: second, .font: NSFont(name: "Helvetica", size: 18)!]))
        let parsed = RichTextAttributed.richText(from: source, pasted: true).text
        XCTAssertEqual(parsed.blocks.map(\.list), [[.bullet], [.bullet, .numbered]])
        XCTAssertEqual(parsed.blocks.map(\.text), ["Top", "Nested"])
        XCTAssertEqual(parsed.blocks[0].runs.first?.style, .bold)
    }

    @MainActor private final class UndoDelegate: NSObject, NSTextViewDelegate {
        let undo: UndoManager = {
            let manager = UndoManager()
            manager.groupsByEvent = false
            return manager
        }()
        func undoManager(for view: NSTextView) -> UndoManager? { undo }
    }

    func testUndoAfterReturnInAListTakesBackTheLineAndItsMarker() {
        let view = makeView(RichText(blocks: [RichText.Block(runs: [RichText.Run(text: "first")], list: [.numbered])]))
        view.allowsUndo = true
        let delegate = UndoDelegate()
        view.delegate = delegate
        moveToEnd(view)
        delegate.undo.beginUndoGrouping()
        type("!", into: view)
        delegate.undo.endUndoGrouping()
        delegate.undo.beginUndoGrouping()
        view.insertNewline(nil)
        delegate.undo.endUndoGrouping()
        XCTAssertEqual(view.string, "\t1.\tfirst!\n\t2.\t")
        delegate.undo.undo()
        XCTAssertEqual(view.string, "\t1.\tfirst!")
    }

    func testLoadingATextDropsTheOldUndoSteps() {
        let editor = RichTextEditor(text: .constant("a"), images: .constant([]), controller: RichTextEditorController())
        let coordinator = editor.makeCoordinator()
        let view = makeView()
        let undo = coordinator.undoManager(for: view)!
        undo.registerUndo(withTarget: view) { _ in }
        XCTAssertTrue(undo.canUndo)
        coordinator.load(text: "b", images: [], into: view)
        XCTAssertFalse(undo.canUndo)
        XCTAssertEqual(view.string, "b")
    }

    func testEveryNumberingCountsAsNumbered() {
        for format in [NSTextList.MarkerFormat.decimal, .lowercaseHexadecimal, .octal, .uppercaseRoman, .lowercaseLatin] {
            let style = NSMutableParagraphStyle()
            style.textLists = [NSTextList(markerFormat: format, options: 0)]
            XCTAssertEqual(RichTextAttributed.list(of: style), [.numbered], format.rawValue)
        }
        let bullets = NSMutableParagraphStyle()
        bullets.textLists = [NSTextList(markerFormat: .hyphen, options: 0)]
        XCTAssertEqual(RichTextAttributed.list(of: bullets), [.bullet])
    }

    func testSelectionParagraphs() {
        let view = makeView("ab\ncd\n")
        XCTAssertEqual(view.paragraphs(touching: NSRange(location: 1, length: 0)).map(\.content), [NSRange(location: 0, length: 2)])
        XCTAssertEqual(view.paragraphs(touching: NSRange(location: 1, length: 3)).map(\.content.location), [0, 3])
        // A whole first line picked, its line break included: the second line is not touched.
        XCTAssertEqual(view.paragraphs(touching: NSRange(location: 0, length: 3)).map(\.content.location), [0])
        XCTAssertEqual(view.paragraphs(touching: NSRange(location: 6, length: 0)).map(\.content), [NSRange(location: 6, length: 0)])
        let plain = makeView("abc")
        XCTAssertEqual(plain.paragraphs(touching: NSRange(location: 3, length: 0)).map(\.content), [NSRange(location: 0, length: 3)])
        XCTAssertEqual(makeView().paragraphs(touching: NSRange(location: 0, length: 0)).count, 1)
    }

    func testOfflineHTMLDropsWhatWouldLoad() {
        let html = #"""
        <table background="http://x/bg.gif"><tr><td style="color:red;background:&#117;rl(http://x/e.png)">Hi</td></tr></table>\#
        <p style="background:u\72l(http://x/c.png)">there</p><img src="http://x/p.png"><picture><source srcset="http://x/s.png"></picture>\#
        <style>@import "http://x/i.css";</style><script>a()</script><link rel="stylesheet" href="http://x/s.css">\#
        <video poster="http://x/v.png"></video><b style="font-weight:bold">bold</b> <a href="https://ok.example/">link</a>
        """#
        let offline = MailPastedImages.offlineHTML(html)
        for leaked in ["bg.gif", "e.png", "c.png", "p.png", "s.png", "i.css", "s.css", "v.png", "<script"] {
            XCTAssertFalse(offline.contains(leaked), leaked)
        }
        XCTAssertTrue(offline.contains("Hi"))
        XCTAssertTrue(offline.contains(#"<b style="font-weight:bold">bold</b>"#))
        XCTAssertTrue(offline.contains(#"href="https://ok.example/""#))
    }
}
