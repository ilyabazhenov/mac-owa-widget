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

    func testCreatesFixedHalfHourlySlotsFromEightToTwentyTwo() {
        let slots = TimelineMeetingLayout.makeHourSlots(
            events: [],
            sectionDate: dayStart,
            calendar: calendar
        )

        XCTAssertEqual(slots.count, 28)
        XCTAssertEqual(calendar.component(.hour, from: slots.first!.startDate), 8)
        XCTAssertEqual(calendar.component(.minute, from: slots.first!.startDate), 0)
        XCTAssertEqual(calendar.component(.hour, from: slots.last!.startDate), 21)
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

        XCTAssertEqual(slot(withHour: 8, minute: 0, in: slots)?.items.map(\.event.id), ["a"])
        XCTAssertEqual(slot(withHour: 21, minute: 30, in: slots)?.items.map(\.event.id), [])
        XCTAssertNil(slot(withHour: 22, minute: 0, in: slots))
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
