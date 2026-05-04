import XCTest
@testable import OWAWidget

@MainActor
final class TimelineMeetingBlockViewTests: XCTestCase {
    func testMeetingTitleTopPaddingIsPositiveInRegularMode() {
        let view = TimelineMeetingBlockView(event: sampleEvent(), compact: false)

        XCTAssertEqual(view.contentTopPadding, 3)
    }

    private func sampleEvent() -> CalendarEvent {
        let startDate = Date(timeIntervalSince1970: 1_700_000_000)
        let endDate = startDate.addingTimeInterval(30 * 60)

        return CalendarEvent(
            id: "sample",
            title: "Sample Meeting",
            startDate: startDate,
            endDate: endDate,
            location: nil,
            bodyPreview: nil,
            joinURL: nil,
            platform: .generic,
            isAllDay: false,
            organizer: nil,
            accountID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        )
    }
}
