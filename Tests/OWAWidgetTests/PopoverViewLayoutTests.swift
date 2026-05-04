import XCTest
@testable import OWAWidget

@MainActor
final class PopoverViewLayoutTests: XCTestCase {
    func testContentHorizontalPaddingMatchesTimelinePadding() {
        let popover = PopoverView()
        let list = MeetingListView(sections: [])

        XCTAssertEqual(popover.contentHorizontalPadding, list.contentHorizontalPadding)
    }
}
