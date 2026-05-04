import XCTest
@testable import OWAWidget

@MainActor
final class MeetingListViewLayoutTests: XCTestCase {
    func testContentHorizontalPaddingIsReduced() {
        let view = MeetingListView(sections: [])

        XCTAssertEqual(view.contentHorizontalPadding, 12)
    }
}
