import XCTest
@testable import OWAWidget

final class MeetingAccentColorResolverTests: XCTestCase {
    func testRussianYellowCategoryMapsToYellowAccent() {
        let accent = meetingCategoryColor(from: ["Желтая категория"])
        XCTAssertEqual(accent, .yellow)
    }

    func testEnglishBlueCategoryMapsToBlueAccent() {
        let accent = meetingCategoryColor(from: ["Blue category"])
        XCTAssertEqual(accent, .blue)
    }

    func testUnknownCategoryReturnsNilAccent() {
        let accent = meetingCategoryColor(from: ["Product sync"])
        XCTAssertNil(accent)
    }

    func testRussianLilacCategoryMapsToPurpleAccent() {
        let accent = meetingCategoryColor(from: ["Лиловая категория"])
        XCTAssertEqual(accent, .purple)
    }
}
