import XCTest
@testable import OWAWidget

final class OWAPersonSearchTokenMatchTests: XCTestCase {

    func testCyrillicTokenMatchesLatinDisplayName() {
        XCTAssertTrue(
            OWAPersonSearchTokenMatch.personContainsToken(
                displayName: "Kovalenko Ivan Petrovich",
                email: "i.kovalenko@example.com",
                token: "иван"
            )
        )
    }

    func testCyrillicTokenMatchesCyrillicDisplayName() {
        XCTAssertTrue(
            OWAPersonSearchTokenMatch.personContainsToken(
                displayName: "Коваленко Иван",
                email: "i.kovalenko@example.com",
                token: "иван"
            )
        )
    }

    func testLatinTokenMatchesCyrillicDisplayName() {
        XCTAssertTrue(
            OWAPersonSearchTokenMatch.personContainsToken(
                displayName: "Коваленко Иван",
                email: "x@y.com",
                token: "ivan"
            )
        )
    }

    func testNonMatchingToken() {
        XCTAssertFalse(
            OWAPersonSearchTokenMatch.personContainsToken(
                displayName: "Kovalenko Ivan",
                email: "i.kovalenko@example.com",
                token: "пётр"
            )
        )
    }
}
