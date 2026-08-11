import XCTest
import AppKit
@testable import OWAWidget

final class MeetingBodyAttributedBuilderTests: XCTestCase {

    private let font = NSFont.systemFont(ofSize: 12)

    private func build(_ nodes: [MeetingBodyDocument.Node]) -> NSAttributedString {
        MeetingBodyAttributedBuilder.attributedString(
            for: nodes,
            font: font,
            color: .secondaryLabelColor,
            linkColor: .linkColor
        )
    }

    private func node(_ kind: MeetingBodyDocument.Node.Kind) -> MeetingBodyDocument.Node {
        MeetingBodyDocument.Node(kind: kind)
    }

    func testBulletKeepsMarkerAndGetsHangingIndent() throws {
        let result = build([node(.text("• Кредитные каникулы"))])

        XCTAssertEqual(result.string, "• Кредитные каникулы")
        let style = try XCTUnwrap(result.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        // The wrapped part of a bullet must sit under the text, not under the marker.
        XCTAssertGreaterThan(style.headIndent, style.firstLineHeadIndent)
    }

    func testNestedBulletIsIndentedFurther() throws {
        let result = build([node(.text("• Госпочта\n◦ 103ф"))])
        let lines = result.string.components(separatedBy: "\n")
        XCTAssertEqual(lines, ["• Госпочта", "◦ 103ф"])

        let nestedStart = try XCTUnwrap(result.string.range(of: "◦")).lowerBound.utf16Offset(in: result.string)
        let outer = try XCTUnwrap(result.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        let nested = try XCTUnwrap(result.attribute(.paragraphStyle, at: nestedStart, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertGreaterThan(nested.firstLineHeadIndent, outer.firstLineHeadIndent)
    }

    func testLinksBecomeClickableAttributes() throws {
        let result = build([node(.text("Материалы https://wiki.example.com/page"))])

        let location = try XCTUnwrap(result.string.range(of: "https")).lowerBound.utf16Offset(in: result.string)
        let url = try XCTUnwrap(result.attribute(.link, at: location, effectiveRange: nil) as? URL)
        XCTAssertEqual(url.absoluteString, "https://wiki.example.com/page")
        // Plain text before the link carries no link attribute.
        XCTAssertNil(result.attribute(.link, at: 0, effectiveRange: nil))
    }

    func testTableCellsBecomeTextTableBlocks() throws {
        let table = MeetingBodyDocument.Table(rows: [["Блок", "Тайминг"], ["Soft", "12:00"]], hasHeaderRow: true)

        let result = build([node(.table(table))])

        let style = try XCTUnwrap(result.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        let block = try XCTUnwrap(style.textBlocks.first as? NSTextTableBlock)
        XCTAssertEqual(block.table.numberOfColumns, 2)
        XCTAssertEqual(block.startingRow, 0)
        // Four cells, four paragraphs — every cell keeps its terminator so the table can lay out.
        XCTAssertEqual(result.string.filter { $0 == "\n" }.count, 4)
    }

    func testHeaderRowIsBoldAndDataRowIsNot() throws {
        let table = MeetingBodyDocument.Table(rows: [["Блок", "Тайминг"], ["Soft", "12:00"]], hasHeaderRow: true)

        let result = build([node(.table(table))])

        let headerFont = try XCTUnwrap(result.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        let dataStart = try XCTUnwrap(result.string.range(of: "Soft")).lowerBound.utf16Offset(in: result.string)
        let dataFont = try XCTUnwrap(result.attribute(.font, at: dataStart, effectiveRange: nil) as? NSFont)

        XCTAssertTrue(NSFontManager.shared.traits(of: headerFont).contains(.boldFontMask))
        XCTAssertFalse(NSFontManager.shared.traits(of: dataFont).contains(.boldFontMask))
    }

    /// An empty cell still needs a paragraph, otherwise its row collapses in the table layout.
    func testEmptyCellStillProducesAParagraph() throws {
        let table = MeetingBodyDocument.Table(rows: [["Данные", ""]], hasHeaderRow: false)

        let result = build([node(.table(table))])

        XCTAssertEqual(result.string.filter { $0 == "\n" }.count, 2)
    }

    /// Links inside a cell get the same treatment as links in running text.
    func testLinkInsideTableCellIsClickable() throws {
        let table = MeetingBodyDocument.Table(
            rows: [["Материалы", "https://wiki.example.com/page"]],
            hasHeaderRow: false
        )

        let result = build([node(.table(table))])

        let location = try XCTUnwrap(result.string.range(of: "https")).lowerBound.utf16Offset(in: result.string)
        let url = try XCTUnwrap(result.attribute(.link, at: location, effectiveRange: nil) as? URL)
        XCTAssertEqual(url.absoluteString, "https://wiki.example.com/page")
        // Still part of the table, not a paragraph that escaped it.
        let style = try XCTUnwrap(result.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertFalse(style.textBlocks.isEmpty)
    }

    /// A bullet list inside a cell keeps both its marker and the cell it belongs to.
    func testBulletsInsideCellStayInTheirBlock() throws {
        let table = MeetingBodyDocument.Table(rows: [["Задачи", "• Колл-листы\n◦ 103ф"]], hasHeaderRow: false)

        let result = build([node(.table(table))])

        XCTAssertTrue(result.string.contains("• Колл-листы"))
        let nestedStart = try XCTUnwrap(result.string.range(of: "◦")).lowerBound.utf16Offset(in: result.string)
        let style = try XCTUnwrap(result.attribute(.paragraphStyle, at: nestedStart, effectiveRange: nil) as? NSParagraphStyle)
        let block = try XCTUnwrap(style.textBlocks.first as? NSTextTableBlock)
        XCTAssertEqual(block.startingColumn, 1)
        XCTAssertGreaterThan(style.headIndent, 0)
    }

    /// A blank line in the source becomes paragraph spacing, not an empty line.
    func testGapBecomesParagraphSpacing() throws {
        let result = build([node(.text("Первый абзац\n\nВторой абзац"))])

        XCTAssertEqual(result.string, "Первый абзац\nВторой абзац")
        let secondStart = try XCTUnwrap(result.string.range(of: "Второй")).lowerBound.utf16Offset(in: result.string)
        let first = try XCTUnwrap(result.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        let second = try XCTUnwrap(result.attribute(.paragraphStyle, at: secondStart, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(first.paragraphSpacingBefore, 0)
        XCTAssertGreaterThan(second.paragraphSpacingBefore, 0)
    }

    func testEmptyDocumentProducesEmptyString() {
        XCTAssertEqual(build([]).length, 0)
    }
}
