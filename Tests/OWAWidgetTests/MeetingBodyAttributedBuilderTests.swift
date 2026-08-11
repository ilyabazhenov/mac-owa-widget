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
        MeetingBodyDocument.Node(id: 0, kind: kind)
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

    func testEmptyDocumentProducesEmptyString() {
        XCTAssertEqual(build([]).length, 0)
    }
}
