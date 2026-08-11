import XCTest
@testable import OWAWidget

final class MeetingBodyLayoutTests: XCTestCase {

    func testSplitsBulletsAndParagraphs() {
        let body = """
        Блок | Тайминг | Задачи
        • Колл-листы
        ◦ 103ф
        """

        let blocks = MeetingBodyLayout.blocks(from: body)

        XCTAssertEqual(blocks.map(\.kind), [.paragraph, .bullet(level: 1), .bullet(level: 2)])
        XCTAssertEqual(blocks.map(\.text), ["Блок | Тайминг | Задачи", "Колл-листы", "103ф"])
    }

    /// A blank line becomes spacing on the next block, not an empty row.
    func testBlankLineBecomesGapOnNextBlock() {
        let blocks = MeetingBodyLayout.blocks(from: "Первый абзац\n\nВторой абзац")

        XCTAssertEqual(blocks.count, 2)
        XCTAssertFalse(blocks[0].hasGapBefore)
        XCTAssertTrue(blocks[1].hasGapBefore)
    }

    func testLeadingBlankLinesProduceNoGap() {
        let blocks = MeetingBodyLayout.blocks(from: "\n\nПервая строка")

        XCTAssertEqual(blocks.count, 1)
        XCTAssertFalse(blocks[0].hasGapBefore)
    }

    /// Plain-text bodies (no HTML) carry no markers and stay ordinary paragraphs.
    func testPlainBodyHasNoBullets() {
        let blocks = MeetingBodyLayout.blocks(from: "Обсудим планы\nи сроки")

        XCTAssertEqual(blocks.map(\.kind), [.paragraph, .paragraph])
    }

    /// A dash list must not be mistaken for a bullet: only the markers the converter emits count.
    func testDashLineIsAParagraph() {
        let blocks = MeetingBodyLayout.blocks(from: "- не наш маркер")

        XCTAssertEqual(blocks.map(\.kind), [.paragraph])
        XCTAssertEqual(blocks.first?.text, "- не наш маркер")
    }
}
