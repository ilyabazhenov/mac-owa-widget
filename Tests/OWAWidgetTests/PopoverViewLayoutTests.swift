import XCTest
@testable import OWAWidget

@MainActor
final class PopoverViewLayoutTests: XCTestCase {
    func testContentHorizontalPaddingMatchesTimelinePadding() {
        let popover = PopoverView()
        let list = MeetingListView(sections: [])

        XCTAssertEqual(popover.contentHorizontalPadding, list.contentHorizontalPadding)
    }

    func testDateNavBarPolicyShowsJumpToTodayOnlyForFutureOffsets() {
        XCTAssertFalse(PopoverView.DateNavBarPolicy.shouldShowJumpToToday(selectedDayOffset: 0))
        XCTAssertTrue(PopoverView.DateNavBarPolicy.shouldShowJumpToToday(selectedDayOffset: 1))
        XCTAssertTrue(PopoverView.DateNavBarPolicy.shouldShowJumpToToday(selectedDayOffset: 6))
    }

    func testDateNavBarPolicyRespectsPreviousAndNextBounds() {
        XCTAssertFalse(PopoverView.DateNavBarPolicy.canGoToPreviousDay(selectedDayOffset: 0))
        XCTAssertTrue(PopoverView.DateNavBarPolicy.canGoToPreviousDay(selectedDayOffset: 2))

        XCTAssertTrue(PopoverView.DateNavBarPolicy.canGoToNextDay(selectedDayOffset: 5, maxDayOffset: 6))
        XCTAssertFalse(PopoverView.DateNavBarPolicy.canGoToNextDay(selectedDayOffset: 6, maxDayOffset: 6))
    }

    func testMeetingDetailStatePolicyResetsSelectedEventOnPopoverDisappear() {
        let event = makeEvent(id: "selected")

        let result = PopoverView.MeetingDetailStatePolicy.selectedEventAfterPopoverDisappear(event)

        XCTAssertNil(result)
    }

    func testMeetingDetailStatePolicyKeepsNilWhenNothingSelected() {
        let result = PopoverView.MeetingDetailStatePolicy.selectedEventAfterPopoverDisappear(nil)

        XCTAssertNil(result)
    }

    private func makeEvent(id: String) -> CalendarEvent {
        CalendarEvent(
            id: id,
            title: "Team sync",
            startDate: Date(timeIntervalSince1970: 1_700_000_000),
            endDate: Date(timeIntervalSince1970: 1_700_000_600),
            location: nil,
            bodyPreview: nil,
            joinURL: nil,
            platform: .teams,
            isAllDay: false,
            organizer: nil,
            accountID: UUID()
        )
    }
}
