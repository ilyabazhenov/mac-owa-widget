import XCTest
@testable import OWAWidget

final class MeetingFreeSlotCalculatorTests: XCTestCase {

    private var moscow: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Moscow")!
        return cal
    }

    private func moscowDate(year: Int, month: Int, day: Int, hour: Int, minute: Int) -> Date {
        moscow.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func assertEqualDates(_ a: Date, _ b: Date, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThanOrEqual(abs(a.timeIntervalSince(b)), 1.0, file: file, line: line)
    }

    private func account() -> UUID { UUID() }

    /// Monday 2025-05-12 00:00 MSK — weekday 2 (Monday).
    private var weekStartMidnight: Date { moscowDate(year: 2025, month: 5, day: 12, hour: 0, minute: 0) }

    private func attendee(allFreeSlotCount: Int, windowStart: Date? = nil) -> AttendeeAvailability {
        let start = windowStart ?? weekStartMidnight
        let fb = String(repeating: "0", count: allFreeSlotCount)
        return AttendeeAvailability(email: "guest@example.com", mergedFreeBusy: fb, windowStart: start, intervalMinutes: 30)
    }

    private func event(
        start: Date,
        end: Date,
        accountID: UUID,
        title: String = "Busy",
        response: MeetingResponseType = .accepted
    ) -> CalendarEvent {
        CalendarEvent(
            id: UUID().uuidString,
            title: title,
            startDate: start,
            endDate: end,
            location: nil,
            bodyPreview: nil,
            joinURL: nil,
            platform: .teams,
            isAllDay: false,
            organizer: nil,
            accountID: accountID,
            isCancelled: false,
            responseType: response
        )
    }

    func testFindsFirstFree30MinSlotOnMondayMorning() {
        let range = DateInterval(
            start: moscowDate(year: 2025, month: 5, day: 12, hour: 10, minute: 0),
            end: moscowDate(year: 2025, month: 5, day: 12, hour: 10, minute: 35)
        )
        let avail = attendee(allFreeSlotCount: 48)
        let slots = MeetingFreeSlotCalculator.compute(
            from: [avail],
            organizerAvailability: nil,
            organizerEvents: [],
            range: range,
            durationMinutes: 30
        )
        XCTAssertEqual(slots.count, 1)
        assertEqualDates(slots[0].start, moscowDate(year: 2025, month: 5, day: 12, hour: 10, minute: 0))
        assertEqualDates(slots[0].end, moscowDate(year: 2025, month: 5, day: 12, hour: 10, minute: 30))
    }

    func testOrganizerCalendarEventBlocksSlot() {
        let acc = account()
        let range = DateInterval(
            start: moscowDate(year: 2025, month: 5, day: 12, hour: 10, minute: 0),
            end: moscowDate(year: 2025, month: 5, day: 12, hour: 11, minute: 35)
        )
        let avail = attendee(allFreeSlotCount: 48)
        let busy = event(
            start: moscowDate(year: 2025, month: 5, day: 12, hour: 10, minute: 0),
            end: moscowDate(year: 2025, month: 5, day: 12, hour: 11, minute: 0),
            accountID: acc
        )
        let slots = MeetingFreeSlotCalculator.compute(
            from: [avail],
            organizerAvailability: nil,
            organizerEvents: [busy],
            range: range,
            durationMinutes: 30
        )
        XCTAssertEqual(slots.count, 1)
        assertEqualDates(slots[0].start, moscowDate(year: 2025, month: 5, day: 12, hour: 11, minute: 0))
    }

    func testMergedFreeBusyBusyDigitSkipsSlot() {
        var fb = String(repeating: "0", count: 48)
        let idx = 20 // 10:00 from midnight Monday
        fb.replaceSubrange(fb.index(fb.startIndex, offsetBy: idx)..<fb.index(fb.startIndex, offsetBy: idx + 1), with: "2")
        let avail = AttendeeAvailability(
            email: "guest@example.com",
            mergedFreeBusy: fb,
            windowStart: weekStartMidnight,
            intervalMinutes: 30
        )
        let range = DateInterval(
            start: moscowDate(year: 2025, month: 5, day: 12, hour: 10, minute: 0),
            end: moscowDate(year: 2025, month: 5, day: 12, hour: 11, minute: 0)
        )
        let slots = MeetingFreeSlotCalculator.compute(
            from: [avail],
            organizerAvailability: nil,
            organizerEvents: [],
            range: range,
            durationMinutes: 30
        )
        XCTAssertEqual(slots.count, 1)
        assertEqualDates(slots[0].start, moscowDate(year: 2025, month: 5, day: 12, hour: 10, minute: 30))
    }

    func testWeekendProducesNoSlots() {
        // Sunday 2025-05-11
        let sundayMidnight = moscowDate(year: 2025, month: 5, day: 11, hour: 0, minute: 0)
        let avail = attendee(allFreeSlotCount: 48, windowStart: sundayMidnight)
        let range = DateInterval(
            start: moscowDate(year: 2025, month: 5, day: 11, hour: 10, minute: 0),
            end: moscowDate(year: 2025, month: 5, day: 11, hour: 14, minute: 0)
        )
        let slots = MeetingFreeSlotCalculator.compute(
            from: [avail],
            organizerAvailability: nil,
            organizerEvents: [],
            range: range,
            durationMinutes: 30
        )
        XCTAssertTrue(slots.isEmpty)
    }

    func testSixtyMinuteFindsMultipleNonOverlappingSlots() {
        let avail = attendee(allFreeSlotCount: 48)
        let range = DateInterval(
            start: moscowDate(year: 2025, month: 5, day: 12, hour: 10, minute: 0),
            end: moscowDate(year: 2025, month: 5, day: 12, hour: 12, minute: 0)
        )
        let slots = MeetingFreeSlotCalculator.compute(
            from: [avail],
            organizerAvailability: nil,
            organizerEvents: [],
            range: range,
            durationMinutes: 60
        )
        XCTAssertEqual(slots.count, 2)
        assertEqualDates(slots[0].start, moscowDate(year: 2025, month: 5, day: 12, hour: 10, minute: 0))
        assertEqualDates(slots[0].end, moscowDate(year: 2025, month: 5, day: 12, hour: 11, minute: 0))
        // After a 60-minute hit, `i` advances by `slotsNeeded` (2 half-hour steps), so next slot is 11:00, not 10:30.
        assertEqualDates(slots[1].start, moscowDate(year: 2025, month: 5, day: 12, hour: 11, minute: 0))
        assertEqualDates(slots[1].end, moscowDate(year: 2025, month: 5, day: 12, hour: 12, minute: 0))
    }

    func testOrganizerAvailabilityApiBlocksWhenBusy() {
        let range = DateInterval(
            start: moscowDate(year: 2025, month: 5, day: 12, hour: 10, minute: 0),
            end: moscowDate(year: 2025, month: 5, day: 12, hour: 11, minute: 0)
        )
        let guest = attendee(allFreeSlotCount: 48)
        var orgFb = String(repeating: "0", count: 48)
        let orgIdx = 20
        orgFb.replaceSubrange(
            orgFb.index(orgFb.startIndex, offsetBy: orgIdx)..<orgFb.index(orgFb.startIndex, offsetBy: orgIdx + 1),
            with: "2"
        )
        let orgAvail = AttendeeAvailability(
            email: "org@example.com",
            mergedFreeBusy: orgFb,
            windowStart: weekStartMidnight,
            intervalMinutes: 30
        )
        let slots = MeetingFreeSlotCalculator.compute(
            from: [guest],
            organizerAvailability: orgAvail,
            organizerEvents: [],
            range: range,
            durationMinutes: 30
        )
        XCTAssertEqual(slots.count, 1)
        assertEqualDates(slots[0].start, moscowDate(year: 2025, month: 5, day: 12, hour: 10, minute: 30))
    }

    func testCapsReturnedFreeSlots() {
        let avail = attendee(allFreeSlotCount: 5000)
        let range = DateInterval(
            start: moscowDate(year: 2025, month: 5, day: 12, hour: 9, minute: 0),
            end: moscowDate(year: 2025, month: 5, day: 30, hour: 18, minute: 0)
        )
        let slots = MeetingFreeSlotCalculator.compute(
            from: [avail],
            organizerAvailability: nil,
            organizerEvents: [],
            range: range,
            durationMinutes: 30
        )
        XCTAssertEqual(slots.count, MeetingFreeSlotCalculator.maxReturnedFreeSlots)
    }

    /// Regression: old hard cap (10) hid Thu–Fri when Mon–Wed had enough free half-hours.
    func testFullMonFriWorkWeekIncludesFridayAfternoon() {
        let avail = attendee(allFreeSlotCount: 500)
        let range = DateInterval(
            start: moscowDate(year: 2025, month: 5, day: 12, hour: 9, minute: 0),
            end: moscowDate(year: 2025, month: 5, day: 16, hour: 18, minute: 0)
        )
        let slots = MeetingFreeSlotCalculator.compute(
            from: [avail],
            organizerAvailability: nil,
            organizerEvents: [],
            range: range,
            durationMinutes: 30
        )
        XCTAssertGreaterThanOrEqual(slots.count, 17, "expect most of Mon; full week has ~85 half-hour starts")
        let fri1730 = moscowDate(year: 2025, month: 5, day: 16, hour: 17, minute: 30)
        XCTAssertTrue(slots.contains { abs($0.start.timeIntervalSince(fri1730)) < 2 })
    }
}
