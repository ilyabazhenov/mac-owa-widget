import XCTest
import AppKit
@testable import OWAWidget

/// End-to-end coverage for the agenda: what the server returns → what the panel displays.
/// The per-stage suites check each transformation; this one checks the seams between them.
final class MeetingBodyRendererTests: XCTestCase {

    /// Shaped like a real invite: a link, running text, and a timetable whose task column is a
    /// nested bullet list — plus the `<head>`/`<style>` Outlook wraps everything in.
    private let invite = """
    <html><head><meta charset="utf-8"><style>p { margin: 0; font-family: "Calibri"; }</style></head>
    <body>
    <p><a href="https://meet.example.com/demo">https://meet.example.com/demo</a></p>
    <p>Коллеги, добрый день!</p>
    <p>Приглашаем на Демо &mdash; повестка ниже</p>
    <table>
    <tr><td><p><b>Блок</b></p></td><td><p><b>Тайминг</b></p></td><td><p><b>Задачи</b></p></td></tr>
    <tr><td><p>Soft \\ Hard</p></td><td><p>12:00 - 12:10</p></td>
    <td><ul><li><p>Колл-листы</p></li><li><p>Госпочта</p><ul type="circle"><li><p>103ф</p></li></ul></li></ul></td></tr>
    </table>
    <p>Материалы: <a href="https://wiki.example.com/page">страничка</a></p>
    </body></html>
    """

    private func render(text: String?, html: String?) -> NSAttributedString? {
        MeetingBodyRenderer.attributedBody(
            text: text,
            html: html,
            font: .systemFont(ofSize: 12),
            color: .secondaryLabelColor,
            linkColor: .linkColor
        )
    }

    private func textBlocks(in string: NSAttributedString) -> [NSTextTableBlock] {
        var blocks: [NSTextTableBlock] = []
        string.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: string.length)) { value, _, _ in
            guard let style = value as? NSParagraphStyle else { return }
            blocks.append(contentsOf: style.textBlocks.compactMap { $0 as? NSTextTableBlock })
        }
        return blocks
    }

    private func links(in string: NSAttributedString) -> [URL] {
        var urls: [URL] = []
        string.enumerateAttribute(.link, in: NSRange(location: 0, length: string.length)) { value, _, _ in
            if let url = value as? URL { urls.append(url) }
        }
        return urls
    }

    func testInviteMarkupSurvivesTheWholePipeline() throws {
        let result = try XCTUnwrap(render(text: "обрезанное превью", html: invite))
        let plain = result.string

        // Stylesheet and markup are gone.
        XCTAssertFalse(plain.contains("font-family"))
        XCTAssertFalse(plain.contains("<"))
        // Entity decoded, bullets and their nesting kept.
        XCTAssertTrue(plain.contains("Приглашаем на Демо — повестка ниже"))
        XCTAssertTrue(plain.contains("• Колл-листы"))
        XCTAssertTrue(plain.contains("◦ 103ф"))
        // The table did not degrade into "cell | cell" text.
        XCTAssertFalse(plain.contains(MeetingBodyHTMLConverter.cellSeparator))
    }

    func testTableFromInviteBecomesRealTextTable() throws {
        let result = try XCTUnwrap(render(text: "превью", html: invite))

        let blocks = textBlocks(in: result)
        XCTAssertFalse(blocks.isEmpty)
        XCTAssertEqual(blocks.first?.table.numberOfColumns, 3)
        // Two rows × three columns, every cell contributing at least one paragraph.
        XCTAssertEqual(Set(blocks.map(\.startingRow)), [0, 1])
        XCTAssertEqual(Set(blocks.map(\.startingColumn)), [0, 1, 2])
    }

    func testBothLinksStayClickableIncludingTheLabelledOne() throws {
        let result = try XCTUnwrap(render(text: "превью", html: invite))

        let urls = links(in: result).map(\.absoluteString)
        XCTAssertTrue(urls.contains("https://meet.example.com/demo"))
        // The labelled anchor keeps its destination through the href-in-parentheses form.
        XCTAssertTrue(urls.contains("https://wiki.example.com/page"))
    }

    /// After a restart only the cached plain text is around — the same body must still render,
    /// just without a grid.
    func testWithoutMarkupTheTextStillRendersButHasNoTable() throws {
        let result = try XCTUnwrap(render(text: "Повестка\n• Первый пункт", html: nil))

        XCTAssertEqual(result.string, "Повестка\n• Первый пункт")
        XCTAssertTrue(textBlocks(in: result).isEmpty)
    }

    func testMarkupWinsOverPlainTextWhenBothArePresent() throws {
        let result = try XCTUnwrap(render(text: "обрезанное превью", html: "<p>Полная повестка</p>"))

        XCTAssertEqual(result.string, "Полная повестка")
    }

    func testEmptyBodyRendersNothing() {
        XCTAssertNil(render(text: nil, html: nil))
        XCTAssertNil(render(text: "   \n  ", html: nil))
        // Markup that carries no text must not produce an empty card section either.
        XCTAssertNil(render(text: "   ", html: "<p> </p>"))
    }
}
