import XCTest
@testable import OWAWidget

final class MeetingBodyDocumentTests: XCTestCase {

    private func table(_ node: MeetingBodyDocument.Node?) -> MeetingBodyDocument.Table? {
        guard case .table(let table)? = node?.kind else { return nil }
        return table
    }

    private func text(_ node: MeetingBodyDocument.Node?) -> String? {
        guard case .text(let text)? = node?.kind else { return nil }
        return text
    }

    func testSplitsTextAndTable() throws {
        let html = """
        <p>Коллеги, добрый день!</p>
        <table><tr><td><p>Блок</p></td><td><p>Тайминг</p></td></tr>
        <tr><td><p>Soft \\ Hard</p></td><td><p>12:00 - 12:10</p></td></tr></table>
        <p>До встречи</p>
        """

        let nodes = MeetingBodyDocument.nodes(fromHTML: html)

        XCTAssertEqual(nodes.count, 3)
        XCTAssertEqual(text(nodes.first), "Коллеги, добрый день!")
        XCTAssertEqual(table(nodes[1])?.rows, [["Блок", "Тайминг"], ["Soft \\ Hard", "12:00 - 12:10"]])
        XCTAssertEqual(text(nodes[2]), "До встречи")
    }

    func testCellKeepsItsBulletList() throws {
        let html = """
        <table><tr><td>Soft</td><td><ul><li>Колл-листы</li><li>Госпочта<ul><li>103ф</li></ul></li></ul></td></tr></table>
        """

        let cells = try XCTUnwrap(table(MeetingBodyDocument.nodes(fromHTML: html).first)?.rows.first)

        XCTAssertEqual(cells.count, 2)
        XCTAssertEqual(cells[1], "• Колл-листы\n• Госпочта\n◦ 103ф")
    }

    /// Outlook nests tables for layout; the inner one must not spill extra rows into the outer.
    func testNestedTableStaysInsideItsCell() throws {
        let html = """
        <table><tr><td>Внешняя<table><tr><td>Вложенная</td></tr></table></td><td>Вторая</td></tr></table>
        """

        let parsed = try XCTUnwrap(table(MeetingBodyDocument.nodes(fromHTML: html).first))

        XCTAssertEqual(parsed.rows.count, 1)
        XCTAssertEqual(parsed.rows[0].count, 2)
        XCTAssertTrue(parsed.rows[0][0].contains("Вложенная"))
        XCTAssertEqual(parsed.rows[0][1], "Вторая")
    }

    /// A grid that wide would give a few characters per column in the panel, so it stays text.
    func testTooWideTableFallsBackToText() {
        let cells = (1...MeetingBodyDocument.maxRenderableColumns + 1).map { "<td>Ячейка \($0)</td>" }.joined()
        let nodes = MeetingBodyDocument.nodes(fromHTML: "<table><tr>\(cells)</tr></table>")

        XCTAssertEqual(nodes.count, 1)
        XCTAssertNotNil(text(nodes.first))
        XCTAssertTrue(try XCTUnwrap(text(nodes.first)).contains(" | "))
    }

    func testHeaderDetectedOnlyForShortFirstRow() throws {
        let withHeader = "<table><tr><td>Блок</td><td>Тайминг</td></tr><tr><td>Soft</td><td>12:00</td></tr></table>"
        XCTAssertEqual(table(MeetingBodyDocument.nodes(fromHTML: withHeader).first)?.hasHeaderRow, true)

        let long = String(repeating: "очень длинный заголовок ", count: 3)
        let withoutHeader = "<table><tr><td>\(long)</td><td>Тайминг</td></tr><tr><td>Soft</td><td>12:00</td></tr></table>"
        XCTAssertEqual(table(MeetingBodyDocument.nodes(fromHTML: withoutHeader).first)?.hasHeaderRow, false)

        let singleRow = "<table><tr><td>Блок</td><td>Тайминг</td></tr></table>"
        XCTAssertEqual(table(MeetingBodyDocument.nodes(fromHTML: singleRow).first)?.hasHeaderRow, false)
    }

    func testBlankLinesInsideCellAreCollapsed() throws {
        let html = "<table><tr><td><p>Внешние портфели.</p><p></p><p>Legal</p></td></tr></table>"

        XCTAssertEqual(table(MeetingBodyDocument.nodes(fromHTML: html).first)?.rows.first?.first, "Внешние портфели.\nLegal")
    }

    func testEmptyRowsAreDropped() throws {
        let html = "<table><tr><td></td><td></td></tr><tr><td>Данные</td><td></td></tr></table>"

        XCTAssertEqual(table(MeetingBodyDocument.nodes(fromHTML: html).first)?.rows, [["Данные", ""]])
    }

    func testPlainTextBodyBecomesSingleTextNode() {
        let nodes = MeetingBodyDocument.nodes(fromPlainText: "Обсудим планы\nи сроки")

        XCTAssertEqual(nodes.count, 1)
        XCTAssertEqual(text(nodes.first), "Обсудим планы\nи сроки")
        XCTAssertTrue(MeetingBodyDocument.nodes(fromPlainText: "   ").isEmpty)
    }

    func testBodyWithoutTablesIsOneTextNode() {
        let nodes = MeetingBodyDocument.nodes(fromHTML: "<p>Первый</p><p>Второй</p>")

        XCTAssertEqual(nodes.count, 1)
        XCTAssertEqual(text(nodes.first), "Первый\n\nВторой")
    }
}
