import XCTest
@testable import OWAWidget

@MainActor
final class TimelineMeetingBlockViewTests: XCTestCase {
    func testMeetingTitleTopPaddingIsReducedForShortMeetings() {
        let view = TimelineMeetingBlockView(event: sampleEvent(durationMinutes: 30), compact: false)

        XCTAssertEqual(view.contentTopPadding, 1)
    }

    func testMeetingTitleTopPaddingRemainsDefaultForLongMeetings() {
        let view = TimelineMeetingBlockView(event: sampleEvent(durationMinutes: 60), compact: false)

        XCTAssertEqual(view.contentTopPadding, 3)
    }

    func testSelectedStateEmphasizesBorderWithoutChangingLayoutPadding() {
        let event = sampleEvent(durationMinutes: 60)
        let normal = TimelineMeetingBlockView(event: event, compact: false, isSelected: false)
        let selected = TimelineMeetingBlockView(event: event, compact: false, isSelected: true)

        XCTAssertEqual(selected.contentTopPadding, normal.contentTopPadding)
        XCTAssertGreaterThan(selected.borderWidth, normal.borderWidth)
    }

    private func sampleEvent(durationMinutes: Int) -> CalendarEvent {
        let startDate = Date(timeIntervalSince1970: 1_700_000_000)
        let endDate = startDate.addingTimeInterval(Double(durationMinutes * 60))

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
