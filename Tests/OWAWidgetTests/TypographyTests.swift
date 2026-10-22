import XCTest
@testable import OWAWidget

final class TypographyTests: XCTestCase {
    func testScaleStepsGrowStrictly() {
        let sizes = AppTextStyle.allCases.map(\.pointSize)
        XCTAssertEqual(sizes, sizes.sorted())
        XCTAssertEqual(Set(sizes).count, sizes.count, "two steps of the scale share a size")
    }

    func testReadingSizesStartAtElevenPoints() {
        XCTAssertEqual(AppTextStyle.footnote.pointSize, 11)
        XCTAssertEqual(AppTextStyle.body.pointSize, 12)
        XCTAssertEqual(AppTextStyle.micro.pointSize, 9, "nothing in the interface is smaller than 9 pt")
    }
}
