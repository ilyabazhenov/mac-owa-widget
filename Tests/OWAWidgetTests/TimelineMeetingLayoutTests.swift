import XCTest
@testable import OWAWidget

final class TimelineMeetingLayoutTests: XCTestCase {
    private var calendar: Calendar!
    private var dayStart: Date!

    override func setUp() {
        super.setUp()
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        dayStart = Date(timeIntervalSince1970: 1_700_000_000)
    }

    func testCreatesFixedHalfHourlySlotsForFullDay() {
        let slots = TimelineMeetingLayout.makeHourSlots(
            events: [],
            sectionDate: dayStart,
            calendar: calendar
        )

        XCTAssertEqual(slots.count, 48)
        XCTAssertEqual(calendar.component(.hour, from: slots.first!.startDate), 0)
        XCTAssertEqual(calendar.component(.minute, from: slots.first!.startDate), 0)
        XCTAssertEqual(calendar.component(.hour, from: slots.last!.startDate), 23)
        XCTAssertEqual(calendar.component(.minute, from: slots.last!.startDate), 30)
        XCTAssertTrue(slots.allSatisfy { $0.items.isEmpty })
    }

    func testPlacesEventIntoFirstIntersectingHalfHourSlot() {
        let events = [
            event(id: "a", startHour: 9, startMinute: 30, endHour: 11, endMinute: 15)
        ]

        let slots = TimelineMeetingLayout.makeHourSlots(
            events: events,
            sectionDate: dayStart,
            calendar: calendar
        )

        XCTAssertEqual(slot(withHour: 9, minute: 0, in: slots)?.items.map(\.event.id), [])
        XCTAssertEqual(slot(withHour: 9, minute: 30, in: slots)?.items.map(\.event.id), ["a"])
        XCTAssertEqual(slot(withHour: 10, minute: 0, in: slots)?.items.map(\.event.id), [])
        XCTAssertEqual(slot(withHour: 11, minute: 0, in: slots)?.items.map(\.event.id), [])
    }

    func testDoesNotIncludeEventWhenItStartsAtSlotEndBoundary() {
        let events = [
            event(id: "a", startHour: 9, startMinute: 0, endHour: 10, endMinute: 0),
        ]

        let slots = TimelineMeetingLayout.makeHourSlots(
            events: events,
            sectionDate: dayStart,
            calendar: calendar
        )

        XCTAssertEqual(slot(withHour: 9, minute: 0, in: slots)?.items.map(\.event.id), ["a"])
        XCTAssertTrue(slot(withHour: 9, minute: 30, in: slots)?.items.isEmpty ?? false)
        XCTAssertTrue(slot(withHour: 10, minute: 0, in: slots)?.items.isEmpty ?? false)
    }

    func testShowsOutOfRangeMeetingInFirstVisibleBoundarySlotOnly() {
        let events = [
            event(id: "a", startHour: 7, startMinute: 30, endHour: 22, endMinute: 30)
        ]

        let slots = TimelineMeetingLayout.makeHourSlots(
            events: events,
            sectionDate: dayStart,
            calendar: calendar
        )

        XCTAssertEqual(slot(withHour: 7, minute: 30, in: slots)?.items.map(\.event.id), ["a"])
        XCTAssertEqual(slot(withHour: 21, minute: 30, in: slots)?.items.map(\.event.id), [])
        XCTAssertTrue(slot(withHour: 22, minute: 0, in: slots)?.items.isEmpty ?? false)
    }

    func testBlockMetricsUseExactBoundsWhenGapIsZero() {
        let meeting = event(id: "a", startHour: 20, startMinute: 0, endHour: 20, endMinute: 30)
        let gridStart = calendar.date(bySettingHour: 17, minute: 0, second: 0, of: dayStart)!

        let metrics = TimelineMeetingLayout.blockMetrics(
            for: meeting,
            gridStart: gridStart,
            pointsPerMinute: 1,
            verticalGap: 0
        )

        XCTAssertEqual(metrics.topOffset, 180)
        XCTAssertEqual(metrics.height, 38)
    }

    func testBlockMetricsDoNotDependOnLaneForSimultaneousMeetings() {
        let first = event(id: "a", startHour: 17, startMinute: 30, endHour: 18, endMinute: 0)
        let second = event(id: "b", startHour: 17, startMinute: 30, endHour: 18, endMinute: 30)
        let gridStart = calendar.date(bySettingHour: 17, minute: 0, second: 0, of: dayStart)!

        let firstMetrics = TimelineMeetingLayout.blockMetrics(
            for: first,
            gridStart: gridStart,
            pointsPerMinute: 1,
            verticalGap: 0
        )
        let secondMetrics = TimelineMeetingLayout.blockMetrics(
            for: second,
            gridStart: gridStart,
            pointsPerMinute: 1,
            verticalGap: 0
        )

        XCTAssertEqual(firstMetrics.topOffset, secondMetrics.topOffset)
    }

    func testCardFramesAlignSimultaneousMeetingsAndRemoveLaneGap() {
        let first = event(id: "a", startHour: 17, startMinute: 30, endHour: 18, endMinute: 0)
        let second = event(id: "b", startHour: 17, startMinute: 30, endHour: 18, endMinute: 30)
        let gridStart = calendar.date(bySettingHour: 17, minute: 0, second: 0, of: dayStart)!

        let firstFrame = TimelineMeetingLayout.cardFrame(
            for: first,
            laneIndex: 0,
            laneCount: 2,
            gridStart: gridStart,
            leftInset: 66,
            cardAreaWidth: 300,
            laneSpacing: 0,
            pointsPerMinute: 1,
            verticalGap: 0
        )
        let secondFrame = TimelineMeetingLayout.cardFrame(
            for: second,
            laneIndex: 1,
            laneCount: 2,
            gridStart: gridStart,
            leftInset: 66,
            cardAreaWidth: 300,
            laneSpacing: 0,
            pointsPerMinute: 1,
            verticalGap: 0
        )

        XCTAssertEqual(firstFrame.yOffset, secondFrame.yOffset)
        XCTAssertEqual(firstFrame.xOffset + firstFrame.width, secondFrame.xOffset)
        XCTAssertEqual(firstFrame.centerX, 141)
        XCTAssertEqual(firstFrame.centerY, 49)
        XCTAssertEqual(secondFrame.centerX, 291)
        XCTAssertEqual(secondFrame.centerY, 60)
    }

    func testBlockMetricsClampNegativeGapAndRespectMaxHeight() {
        let meeting = event(id: "a", startHour: 17, startMinute: 0, endHour: 20, endMinute: 30)
        let gridStart = calendar.date(bySettingHour: 17, minute: 0, second: 0, of: dayStart)!

        let metrics = TimelineMeetingLayout.blockMetrics(
            for: meeting,
            gridStart: gridStart,
            pointsPerMinute: 1,
            verticalGap: -12
        )

        XCTAssertEqual(metrics.topOffset, 0)
        XCTAssertEqual(metrics.height, 96)
    }

    func testCardFrameClampsLaneAndWidthInputs() {
        let meeting = event(id: "a", startHour: 17, startMinute: 30, endHour: 18, endMinute: 0)
        let gridStart = calendar.date(bySettingHour: 17, minute: 0, second: 0, of: dayStart)!

        let frame = TimelineMeetingLayout.cardFrame(
            for: meeting,
            laneIndex: 99,
            laneCount: 0,
            gridStart: gridStart,
            leftInset: 66,
            cardAreaWidth: -300,
            laneSpacing: -8,
            pointsPerMinute: 1,
            verticalGap: 0
        )

        XCTAssertEqual(frame.xOffset, 66)
        XCTAssertEqual(frame.yOffset, 30)
        XCTAssertEqual(frame.width, 0)
        XCTAssertEqual(frame.height, 38)
    }

    private func slot(withHour hour: Int, minute: Int, in slots: [DayHourSlot]) -> DayHourSlot? {
        slots.first {
            calendar.component(.hour, from: $0.startDate) == hour &&
            calendar.component(.minute, from: $0.startDate) == minute
        }
    }

    private func event(
        id: String,
        startHour: Int,
        startMinute: Int,
        endHour: Int,
        endMinute: Int
    ) -> CalendarEvent {
        let startDate = calendar.date(
            bySettingHour: startHour,
            minute: startMinute,
            second: 0,
            of: dayStart
        )!
        let endDate = calendar.date(
            bySettingHour: endHour,
            minute: endMinute,
            second: 0,
            of: dayStart
        )!

        return CalendarEvent(
            id: id,
            title: "Event \(id)",
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
