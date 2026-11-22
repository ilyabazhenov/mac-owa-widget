@testable import OWAWidget
import XCTest

final class MCPSearchWordsTests: XCTestCase {
    func testPlainWordsInOrderWithoutRepeats() {
        XCTAssertEqual(MCPSearchWords.hintWords("встройка панели ОПТИ релиз"), ["встройка", "панели", "ОПТИ", "релиз"])
        XCTAssertEqual(MCPSearchWords.hintWords("  Релиз   релиз 60 "), ["Релиз", "60"])
    }

    func testOneWordGetsNoHint() {
        XCTAssertEqual(MCPSearchWords.hintWords("панель"), [])
        XCTAssertEqual(MCPSearchWords.hintWords("Релиз релиз"), [])
        XCTAssertEqual(MCPSearchWords.hintWords(""), [])
    }

    func testSearchSyntaxIsTheCallersOwn() {
        for query in ["встройка OR ОПТИ", "a AND b", "релиз NOT 59", "\"встройка панели\" ОПТИ", "from:a@example.com релиз", "(a b)", "релиз -59", "received>=2026-11-01 релиз", "панел* ОПТИ"] {
            XCTAssertEqual(MCPSearchWords.hintWords(query), [], query)
        }
    }

    func testLowercaseOperatorWordsAreWords() {
        XCTAssertEqual(MCPSearchWords.hintWords("cats or dogs"), ["cats", "or", "dogs"])
    }
}
