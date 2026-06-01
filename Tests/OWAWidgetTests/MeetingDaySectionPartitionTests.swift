import XCTest
@testable import OWAWidget

final class MeetingDaySectionPartitionTests: XCTestCase {
    private let dayStart = Date(timeIntervalSince1970: 1_700_000_000) // фиксированная точка дня
    private var dayEnd: Date { dayStart.addingTimeInterval(24 * 3600) }

    func testAllTimedEventsGoToTimedAndAllDayIsEmpty() {
        let a = makeEvent(id: "a", title: "Standup",
                          start: dayStart.addingTimeInterval(9 * 3600),
                          end: dayStart.addingTimeInterval(9 * 3600 + 30 * 60))
        let b = makeEvent(id: "b", title: "Review",
                          start: dayStart.addingTimeInterval(14 * 3600),
                          end: dayStart.addingTimeInterval(15 * 3600))

        let section = MeetingDaySection.partition(
            events: [a, b], label: "Today", dayStart: dayStart, dayEnd: dayEnd
        )

        XCTAssertEqual(section.timedEvents.map(\.id), ["a", "b"])
        XCTAssertTrue(section.allDayEvents.isEmpty)
    }

    func testAllAllDayEventsGoToAllDayAndTimedIsEmpty() {
        let a = makeEvent(id: "a", title: "Vacation", start: dayStart, end: dayEnd, isAllDay: true)
        let b = makeEvent(id: "b", title: "Conference", start: dayStart, end: dayEnd, isAllDay: true)

        let section = MeetingDaySection.partition(
            events: [a, b], label: "Today", dayStart: dayStart, dayEnd: dayEnd
        )

        XCTAssertTrue(section.timedEvents.isEmpty)
        XCTAssertEqual(section.allDayEvents.count, 2)
    }

    func testMixedEventsAreSplitCorrectly() {
        let allDay = makeEvent(id: "ad", title: "OOO", start: dayStart, end: dayEnd, isAllDay: true)
        let timed = makeEvent(id: "t", title: "Sync",
                              start: dayStart.addingTimeInterval(10 * 3600),
                              end: dayStart.addingTimeInterval(10 * 3600 + 30 * 60))

        let section = MeetingDaySection.partition(
            events: [allDay, timed], label: "Today", dayStart: dayStart, dayEnd: dayEnd
        )

        XCTAssertEqual(section.timedEvents.map(\.id), ["t"])
        XCTAssertEqual(section.allDayEvents.map(\.id), ["ad"])
    }

    func testMultiDayAllDayEventIsIncludedWhenIntersectingTheDay() {
        // событие охватывает три дня; запрашиваем средний день
        let multiDayAllDay = makeEvent(
            id: "vacation",
            title: "Vacation",
            start: dayStart.addingTimeInterval(-24 * 3600),
            end: dayEnd.addingTimeInterval(24 * 3600),
            isAllDay: true
        )

        let section = MeetingDaySection.partition(
            events: [multiDayAllDay], label: "Today", dayStart: dayStart, dayEnd: dayEnd
        )

        XCTAssertEqual(section.allDayEvents.map(\.id), ["vacation"])
        XCTAssertTrue(section.timedEvents.isEmpty)
    }

    func testAllDayEventsSortedCaseInsensitivelyByTitle() {
        let beta = makeEvent(id: "b", title: "beta", start: dayStart, end: dayEnd, isAllDay: true)
        let alpha = makeEvent(id: "a", title: "Alpha", start: dayStart, end: dayEnd, isAllDay: true)
        let gamma = makeEvent(id: "g", title: "gamma", start: dayStart, end: dayEnd, isAllDay: true)

        let section = MeetingDaySection.partition(
            events: [beta, alpha, gamma], label: "Today", dayStart: dayStart, dayEnd: dayEnd
        )

        XCTAssertEqual(section.allDayEvents.map(\.title), ["Alpha", "beta", "gamma"])
    }

    func testEventsOutsideTheDayAreExcluded() {
        let yesterday = makeEvent(
            id: "y", title: "Old",
            start: dayStart.addingTimeInterval(-5 * 3600),
            end: dayStart.addingTimeInterval(-1 * 3600)
        )
        let tomorrow = makeEvent(
            id: "tm", title: "Future",
            start: dayEnd.addingTimeInterval(1 * 3600),
            end: dayEnd.addingTimeInterval(2 * 3600)
        )
        let today = makeEvent(
            id: "t", title: "Now",
            start: dayStart.addingTimeInterval(12 * 3600),
            end: dayStart.addingTimeInterval(13 * 3600)
        )

        let section = MeetingDaySection.partition(
            events: [yesterday, today, tomorrow], label: "Today", dayStart: dayStart, dayEnd: dayEnd
        )

        XCTAssertEqual(section.timedEvents.map(\.id), ["t"])
        XCTAssertTrue(section.allDayEvents.isEmpty)
    }

    func testCancelledAllDayEventStillIncluded() {
        let cancelled = makeEvent(
            id: "c", title: "Cancelled offsite",
            start: dayStart, end: dayEnd, isAllDay: true, isCancelled: true
        )

        let section = MeetingDaySection.partition(
            events: [cancelled], label: "Today", dayStart: dayStart, dayEnd: dayEnd
        )

        XCTAssertEqual(section.allDayEvents.map(\.id), ["c"])
    }

    func testSectionMetadataPreserved() {
        let section = MeetingDaySection.partition(
            events: [], label: "Tomorrow", dayStart: dayStart, dayEnd: dayEnd
        )

        XCTAssertEqual(section.label, "Tomorrow")
        XCTAssertEqual(section.date, dayStart)
    }

    private func makeEvent(
        id: String,
        title: String,
        start: Date,
        end: Date,
        isAllDay: Bool = false,
        isCancelled: Bool = false
    ) -> CalendarEvent {
        CalendarEvent(
            id: id,
            title: title,
            startDate: start,
            endDate: end,
            location: nil,
            bodyPreview: nil,
            joinURL: nil,
            platform: .teams,
            isAllDay: isAllDay,
            organizer: nil,
            accountID: UUID(),
            isCancelled: isCancelled
        )
    }
}
