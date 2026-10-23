import XCTest
@testable import OWAWidget

@MainActor
final class MailDigestScheduleTests: XCTestCase {
    private let calendar = AppTimeZone.calendar
    private let account = UUID()
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func at(_ hour: Int, _ minute: Int = 0, dayOffset: Int = 0) -> Date {
        let day = calendar.date(byAdding: .day, value: dayOffset, to: base)!
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
    }

    private func meeting(
        _ id: String, from start: Date, minutes: Double = 30, join: Bool = false,
        response: MeetingResponseType = .accepted, cancelled: Bool = false, allDay: Bool = false
    ) -> CalendarEvent {
        CalendarEvent(
            id: id, title: id, startDate: start, endDate: start.addingTimeInterval(minutes * 60), location: nil, bodyPreview: nil,
            joinURL: join ? URL(string: "https://teams.microsoft.com/l/meetup-join/\(id)") : nil, platform: .generic,
            isAllDay: allDay, organizer: nil, accountID: account, isCancelled: cancelled, responseType: response
        )
    }

    // MARK: Day load

    func testLoadCountsTodaysMeetingsOnceAndFindsTheFreeTimeLeft() throws {
        let events = [
            meeting("a", from: at(9, 30)),
            meeting("b", from: at(11), minutes: 60),
            meeting("c", from: at(11, 30), minutes: 60),  // overlaps b
            meeting("d", from: at(14), minutes: 60),
            meeting("declined", from: at(15), response: .declined),
            meeting("cancelled", from: at(16), cancelled: true),
            meeting("tomorrow", from: at(10, dayOffset: 1)),
        ]
        let load = try XCTUnwrap(MailDigestSchedule.dayLoad(events: events, now: at(10, 40), calendar: calendar))
        XCTAssertEqual(load.meetingCount, 4)
        XCTAssertEqual(load.meetingSeconds, 3 * 3600, "b and c together are 1.5 h, not 2")
        XCTAssertEqual(load.remainingCount, 3)
        XCTAssertEqual(load.overlaps.count, 1)
        // From now: 10:40–11:00 is too short; 12:30–14:00 and from 15:00 to the end of the day are left.
        XCTAssertEqual(load.freeSlots, [.between(DateInterval(start: at(12, 30), end: at(14))), .after(at(15))])
        XCTAssertEqual(load.blocks.filter(\.isOver).count, 1)
        XCTAssertEqual(load.axis, DateInterval(start: at(9), end: at(18)))
    }

    func testAxisWidensToWholeHoursAroundEarlyAndLateMeetings() throws {
        let events = [meeting("early", from: at(8, 15)), meeting("late", from: at(19, 10))]
        let load = try XCTUnwrap(MailDigestSchedule.dayLoad(events: events, now: at(7), calendar: calendar))
        XCTAssertEqual(load.axis, DateInterval(start: at(8), end: at(20)))
        XCTAssertEqual(load.freeSlots, [.after(at(9))], "working hours only")
    }

    func testNoFreeTimeAfterTheWorkingDayAndNoLineWithoutMeetings() throws {
        let load = try XCTUnwrap(MailDigestSchedule.dayLoad(events: [meeting("a", from: at(10))], now: at(18, 30), calendar: calendar))
        XCTAssertTrue(load.freeSlots.isEmpty)
        XCTAssertEqual(load.remainingCount, 0)
        XCTAssertNil(MailDigestSchedule.dayLoad(events: [meeting("allDay", from: at(0), minutes: 1440, allDay: true)], now: at(10), calendar: calendar))
    }

    func testWindowThatHasBegunIsNamedByItsEnd() throws {
        let load = try XCTUnwrap(MailDigestSchedule.dayLoad(events: [meeting("a", from: at(10, 30))], now: at(9, 13), calendar: calendar))
        XCTAssertEqual(load.freeSlots, [.until(at(10, 30)), .after(at(11))])
    }

    /// The base date is a Friday: the next day is a Saturday, with no working day to be free in.
    func testNoFreeTimeOnADayOff() throws {
        let load = try XCTUnwrap(MailDigestSchedule.dayLoad(events: [meeting("a", from: at(12, dayOffset: 1))], now: at(9, dayOffset: 1), calendar: calendar))
        XCTAssertEqual(load.meetingCount, 1)
        XCTAssertTrue(load.freeSlots.isEmpty)
    }

    /// Working hours are on the clock: on the day the clocks go forward 9:00 is still 9:00.
    func testWorkingHoursFollowTheClockWhenTheClocksChange() throws {
        var berlin = Calendar(identifier: .gregorian)
        berlin.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Berlin"))
        let day = try XCTUnwrap(berlin.date(from: DateComponents(year: 2026, month: 3, day: 29)))
        func clock(_ hour: Int) -> Date { berlin.date(bySettingHour: hour, minute: 0, second: 0, of: day)! }
        var options = ScheduleStatsCalculator.Options()
        options.workDays = Set(1...7)
        let load = try XCTUnwrap(MailDigestSchedule.dayLoad(events: [meeting("a", from: clock(12))], now: clock(7), calendar: berlin, options: options))
        XCTAssertEqual(load.freeSlots, [.between(DateInterval(start: clock(9), end: clock(12))), .after(clock(12).addingTimeInterval(1800))])
    }

    // MARK: Up next

    func testNextMeetingTodayPrefersTheOneWithAJoinLink() {
        let events = [meeting("plain", from: at(11)), meeting("call", from: at(11, 2), join: true), meeting("later", from: at(15))]
        XCTAssertEqual(MailDigestSchedule.nextUp(events: events, now: at(10), calendar: calendar), .upcoming(events[1]))
    }

    func testInProgressNamesTheMeetingAfterIt() {
        let now = at(10, 10)
        let running = meeting("running", from: at(10), minutes: 60)
        let next = meeting("next", from: at(13))
        XCTAssertEqual(MailDigestSchedule.nextUp(events: [running, next], now: now, calendar: calendar), .inProgress(running, next: next))
        let tomorrow = meeting("tomorrow", from: at(9, dayOffset: 1))
        XCTAssertEqual(MailDigestSchedule.nextUp(events: [running, tomorrow], now: now, calendar: calendar), .inProgress(running, next: nil))
    }

    /// As in the popover banner: a meeting starting within five minutes beats the one running.
    func testMeetingAboutToStartWinsOverTheOneRunning() {
        let running = meeting("running", from: at(10), minutes: 60)
        let soon = meeting("soon", from: at(10, 55))
        XCTAssertEqual(MailDigestSchedule.nextUp(events: [running, soon], now: at(10, 52), calendar: calendar), .upcoming(soon))
    }

    func testEveningPointsToTheNextDayAndDeclinedIsNeverNext() {
        let events = [
            meeting("done", from: at(10)),
            meeting("declined", from: at(20), response: .declined),
            meeting("monday", from: at(10, dayOffset: 3)),
        ]
        XCTAssertEqual(MailDigestSchedule.nextUp(events: events, now: at(19), calendar: calendar), .laterDay(events[2]))
        XCTAssertNil(MailDigestSchedule.nextUp(events: [events[0]], now: at(19), calendar: calendar))
    }

    // MARK: Colleagues

    func testFreeColleaguesFirstInTheUsersOrderUnreadableLeftOut() {
        let people: [(String, ColleaguePresence)] = [
            ("busy", .busy), ("free1", .free), ("hidden", .noData), ("tentative", .tentative), ("free2", .free), ("away", .away),
        ]
        let ordered = MailDigestSchedule.orderedColleagues(people) { $0.1 }.map(\.0)
        XCTAssertEqual(ordered, ["free1", "free2", "tentative", "busy", "away"])
    }
}
