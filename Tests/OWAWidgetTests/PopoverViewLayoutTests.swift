import XCTest
@testable import OWAWidget

@MainActor
final class PopoverViewLayoutTests: XCTestCase {
    func testContentHorizontalPaddingMatchesTimelinePadding() {
        let popover = PopoverView()
        let list = MeetingListView(sections: [])

        XCTAssertEqual(popover.contentHorizontalPadding, list.contentHorizontalPadding)
    }

    func testDateNavBarPolicyShowsJumpToTodayForPastAndFutureOffsets() {
        XCTAssertFalse(PopoverView.DateNavBarPolicy.shouldShowJumpToToday(selectedDayOffset: 0))
        XCTAssertTrue(PopoverView.DateNavBarPolicy.shouldShowJumpToToday(selectedDayOffset: 1))
        XCTAssertTrue(PopoverView.DateNavBarPolicy.shouldShowJumpToToday(selectedDayOffset: 6))
        XCTAssertTrue(PopoverView.DateNavBarPolicy.shouldShowJumpToToday(selectedDayOffset: -1))
        XCTAssertTrue(PopoverView.DateNavBarPolicy.shouldShowJumpToToday(selectedDayOffset: -7))
    }

    func testDateNavBarPolicyRespectsPreviousAndNextBounds() {
        XCTAssertTrue(PopoverView.DateNavBarPolicy.canGoToPreviousDay(selectedDayOffset: 0, minDayOffset: -7))
        XCTAssertTrue(PopoverView.DateNavBarPolicy.canGoToPreviousDay(selectedDayOffset: -6, minDayOffset: -7))
        XCTAssertFalse(PopoverView.DateNavBarPolicy.canGoToPreviousDay(selectedDayOffset: -7, minDayOffset: -7))
        XCTAssertTrue(PopoverView.DateNavBarPolicy.canGoToPreviousDay(selectedDayOffset: 2, minDayOffset: -7))

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

    func testNextEventsPolicyIgnoresAllDayTomorrowMeeting() {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now)!
        let allDayStart = calendar.startOfDay(for: tomorrow)
        let allDayEnd = calendar.date(byAdding: .day, value: 1, to: allDayStart)!
        let allDay = makeEvent(
            id: "all-day-tomorrow",
            startDate: allDayStart,
            endDate: allDayEnd,
            isAllDay: true
        )

        let result = PopoverView.NextEventsPolicy.nextEvents(from: [allDay], now: now)

        XCTAssertTrue(result.isEmpty)
    }

    func testNextEventsPolicyKeepsRegularUpcomingMeeting() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let upcoming = makeEvent(
            id: "regular",
            startDate: now.addingTimeInterval(10 * 60),
            endDate: now.addingTimeInterval(40 * 60),
            isAllDay: false
        )

        let result = PopoverView.NextEventsPolicy.nextEvents(from: [upcoming], now: now)

        XCTAssertEqual(result.map(\.id), ["regular"])
    }

    func testNextEventsPolicyHidesBannerWhenEarliestStartsLaterThanThirtyMinutes() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let distant = makeEvent(
            id: "distant",
            startDate: now.addingTimeInterval(31 * 60),
            endDate: now.addingTimeInterval(61 * 60)
        )

        let result = PopoverView.NextEventsPolicy.nextEvents(from: [distant], now: now)

        XCTAssertTrue(result.isEmpty)
    }

    func testNextEventsPolicyPromotesUpcomingWithinFiveMinutesOverCurrentMeeting() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let current = makeEvent(
            id: "current",
            startDate: now.addingTimeInterval(-10 * 60),
            endDate: now.addingTimeInterval(20 * 60)
        )
        let upcomingSoon = makeEvent(
            id: "upcoming-soon",
            startDate: now.addingTimeInterval(4 * 60),
            endDate: now.addingTimeInterval(34 * 60)
        )
        let nearPromoted = makeEvent(
            id: "near-promoted",
            startDate: now.addingTimeInterval(8 * 60),
            endDate: now.addingTimeInterval(38 * 60)
        )

        let result = PopoverView.NextEventsPolicy.nextEvents(from: [current, upcomingSoon, nearPromoted], now: now)

        XCTAssertEqual(result.map(\.id), ["upcoming-soon", "near-promoted"])
    }

    func testNextEventsPolicySortsGroupedEventsWithJoinURLFirst() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let noURL = makeEvent(
            id: "no-url",
            startDate: now.addingTimeInterval(6 * 60),
            endDate: now.addingTimeInterval(36 * 60),
            joinURL: nil
        )
        let withURL = makeEvent(
            id: "with-url",
            startDate: now.addingTimeInterval(7 * 60),
            endDate: now.addingTimeInterval(37 * 60),
            joinURL: URL(string: "https://teams.example.com/join")
        )

        let result = PopoverView.NextEventsPolicy.nextEvents(from: [noURL, withURL], now: now)

        XCTAssertEqual(result.map(\.id), ["with-url", "no-url"])
    }

    func testNextEventsPolicyExcludesEffectivelyCancelledAndCancelledEvents() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let cancelledByTitle = makeEvent(
            id: "cancelled-title",
            startDate: now.addingTimeInterval(5 * 60),
            endDate: now.addingTimeInterval(35 * 60),
            title: "Cancelled: Team sync"
        )
        let cancelledByFlag = makeEvent(
            id: "cancelled-flag",
            startDate: now.addingTimeInterval(6 * 60),
            endDate: now.addingTimeInterval(36 * 60),
            isCancelled: true
        )
        let valid = makeEvent(
            id: "valid",
            startDate: now.addingTimeInterval(7 * 60),
            endDate: now.addingTimeInterval(37 * 60)
        )

        let result = PopoverView.NextEventsPolicy.nextEvents(
            from: [cancelledByTitle, cancelledByFlag, valid],
            now: now
        )

        XCTAssertEqual(result.map(\.id), ["valid"])
    }

    private func makeEvent(
        id: String,
        startDate: Date = Date(timeIntervalSince1970: 1_700_000_000),
        endDate: Date = Date(timeIntervalSince1970: 1_700_000_600),
        isAllDay: Bool = false,
        joinURL: URL? = nil,
        title: String = "Team sync",
        isCancelled: Bool = false
    ) -> CalendarEvent {
        CalendarEvent(
            id: id,
            title: title,
            startDate: startDate,
            endDate: endDate,
            location: nil,
            bodyPreview: nil,
            joinURL: joinURL,
            platform: .teams,
            isAllDay: isAllDay,
            organizer: nil,
            accountID: UUID(),
            isCancelled: isCancelled
        )
    }
}
