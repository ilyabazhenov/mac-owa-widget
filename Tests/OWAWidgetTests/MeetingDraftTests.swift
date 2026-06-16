import XCTest
@testable import OWAWidget

final class MeetingDraftTests: XCTestCase {

    private func makeDraft(weekStart: Date) -> MeetingDraft {
        var d = MeetingDraft()
        d.selectedWeekStart = weekStart
        return d
    }

    func testSlotAutoRefreshKeyIgnoresTitleAndAgenda() {
        let monday = MeetingDraft.mondayOfWeek(containing: Date())
        var a = makeDraft(weekStart: monday)
        a.title = "A"
        a.agenda = "X"
        a.requiredAttendees = [ResolvedAttendee(displayName: "U", email: "u@e.com", jobTitle: nil)]

        var b = makeDraft(weekStart: monday)
        b.title = "B"
        b.agenda = "Y"
        b.requiredAttendees = [ResolvedAttendee(displayName: "U", email: "u@e.com", jobTitle: nil)]

        XCTAssertEqual(a.slotAutoRefreshKey, b.slotAutoRefreshKey)
    }

    func testSlotAutoRefreshKeyStableUnderAttendeeReorder() {
        let u = ResolvedAttendee(displayName: "U", email: "u@e.com", jobTitle: nil)
        let v = ResolvedAttendee(displayName: "V", email: "v@e.com", jobTitle: nil)
        let monday = MeetingDraft.mondayOfWeek(containing: Date())
        var a = makeDraft(weekStart: monday)
        a.requiredAttendees = [u, v]
        var b = makeDraft(weekStart: monday)
        b.requiredAttendees = [v, u]
        XCTAssertEqual(a.slotAutoRefreshKey, b.slotAutoRefreshKey)
    }

    func testSlotAutoRefreshKeyChangesWhenSelectedWeekChanges() {
        let monday = MeetingDraft.mondayOfWeek(containing: Date())
        var a = makeDraft(weekStart: monday)
        var b = makeDraft(weekStart: a.weekStartOffset(by: 1))
        XCTAssertNotEqual(a.slotAutoRefreshKey, b.slotAutoRefreshKey)
    }

    func testSlotAutoRefreshKeyChangesWhenAttendeeSetChanges() {
        let monday = MeetingDraft.mondayOfWeek(containing: Date())
        var a = makeDraft(weekStart: monday)
        a.requiredAttendees = [ResolvedAttendee(displayName: "U", email: "u@e.com", jobTitle: nil)]
        var b = makeDraft(weekStart: monday)
        b.requiredAttendees = [
            ResolvedAttendee(displayName: "U", email: "u@e.com", jobTitle: nil),
            ResolvedAttendee(displayName: "V", email: "v@e.com", jobTitle: nil),
        ]
        XCTAssertNotEqual(a.slotAutoRefreshKey, b.slotAutoRefreshKey)
    }

    func testSlotAutoRefreshKeyIgnoresOptionalAttendeeChanges() {
        let u = ResolvedAttendee(displayName: "U", email: "u@e.com", jobTitle: nil)
        let v = ResolvedAttendee(displayName: "V", email: "v@e.com", jobTitle: nil)
        let monday = MeetingDraft.mondayOfWeek(containing: Date())
        var a = makeDraft(weekStart: monday)
        a.requiredAttendees = [u]
        var b = makeDraft(weekStart: monday)
        b.requiredAttendees = [u]
        b.optionalAttendees = [v]
        // v1: optional attendees do not affect slot search, so the refresh key must not change.
        XCTAssertEqual(a.slotAutoRefreshKey, b.slotAutoRefreshKey)
    }

    func testAllAttendeesCombinesRequiredAndOptional() {
        let u = ResolvedAttendee(displayName: "U", email: "u@e.com", jobTitle: nil)
        let v = ResolvedAttendee(displayName: "V", email: "v@e.com", jobTitle: nil)
        var draft = MeetingDraft()
        draft.requiredAttendees = [u]
        draft.optionalAttendees = [v]
        XCTAssertEqual(draft.allAttendees, [u, v])
        XCTAssertEqual(draft.kind(of: u), .required)
        XCTAssertEqual(draft.kind(of: v), .optional)
    }

    // MARK: - Week navigation

    private var moscow: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Moscow")!
        cal.firstWeekday = 2
        return cal
    }

    private func moscowDate(year: Int, month: Int, day: Int, hour: Int = 0, minute: Int = 0) -> Date {
        moscow.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    func testMondayOfWeekContainingMidweekIsThatWeeksMonday() {
        let wednesday = moscowDate(year: 2025, month: 5, day: 14, hour: 12)
        let monday = MeetingDraft.mondayOfWeek(containing: wednesday)
        let expected = moscowDate(year: 2025, month: 5, day: 12)
        XCTAssertLessThan(abs(monday.timeIntervalSince(expected)), 1.0)
    }

    func testWeekStartOffsetMovesBySevenDays() {
        var d = MeetingDraft()
        d.selectedWeekStart = moscowDate(year: 2025, month: 5, day: 12)
        let next = d.weekStartOffset(by: 1)
        let prev = d.weekStartOffset(by: -1)
        let expectedNext = moscowDate(year: 2025, month: 5, day: 19)
        let expectedPrev = moscowDate(year: 2025, month: 5, day: 5)
        XCTAssertLessThan(abs(next.timeIntervalSince(expectedNext)), 1.0)
        XCTAssertLessThan(abs(prev.timeIntervalSince(expectedPrev)), 1.0)
    }

    func testDateIntervalEndsAtFridaySixPM() {
        var d = MeetingDraft()
        d.selectedWeekStart = moscowDate(year: 2025, month: 5, day: 12)
        // Use a referenceNow well in the past so the start is not clamped to "now".
        let ref = moscowDate(year: 2025, month: 5, day: 12, hour: 8)
        let interval = d.dateInterval(referenceNow: ref)
        let expectedEnd = moscowDate(year: 2025, month: 5, day: 16, hour: 18)
        XCTAssertLessThan(abs(interval.end.timeIntervalSince(expectedEnd)), 1.0)
    }

    func testDateIntervalClampsStartToReferenceForCurrentWeek() {
        var d = MeetingDraft()
        d.selectedWeekStart = moscowDate(year: 2025, month: 5, day: 12)
        let ref = moscowDate(year: 2025, month: 5, day: 14, hour: 11)
        let interval = d.dateInterval(referenceNow: ref)
        XCTAssertLessThan(abs(interval.start.timeIntervalSince(ref)), 1.0)
    }

    func testDateIntervalIsEmptyForPastWeek() {
        var d = MeetingDraft()
        d.selectedWeekStart = moscowDate(year: 2025, month: 5, day: 5)
        let ref = moscowDate(year: 2025, month: 5, day: 14, hour: 11)
        let interval = d.dateInterval(referenceNow: ref)
        XCTAssertEqual(interval.duration, 0)
    }

    func testSlotGridWeekIntervalIsSevenDays() {
        var d = MeetingDraft()
        d.selectedWeekStart = moscowDate(year: 2025, month: 5, day: 12)
        let week = d.slotGridWeekInterval()
        XCTAssertEqual(week.duration, 7 * 86400, accuracy: 1.0)
    }

    // MARK: - Длительность встречи влияет на ключи пере-поиска / пересчёта грида

    func testSlotAutoRefreshKeyChangesWhenDurationChanges() {
        let monday = MeetingDraft.mondayOfWeek(containing: Date())
        let a = makeDraft(weekStart: monday)
        var b = makeDraft(weekStart: monday)
        b.durationMinutes = 120
        XCTAssertNotEqual(a.slotAutoRefreshKey, b.slotAutoRefreshKey,
                          "смена длительности должна перезапускать поиск слотов")
    }

    func testCellMatrixSignatureChangesWhenDurationChanges() {
        let monday = MeetingDraft.mondayOfWeek(containing: Date())
        let a = makeDraft(weekStart: monday)
        var b = makeDraft(weekStart: monday)
        b.durationMinutes = 60
        XCTAssertNotEqual(a.cellMatrixSignature, b.cellMatrixSignature,
                          "смена длительности должна инвалидировать раскраску грида")
    }
}
