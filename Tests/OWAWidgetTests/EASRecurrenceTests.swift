import XCTest
@testable import OWAWidget

/// Expanding a repetition rule into occurrences.
///
/// This is the part of the ActiveSync provider with no server-side safety net: Exchange sends a
/// rule and trusts the client to produce the meetings. Everything here fails silently when
/// wrong — a meeting at the wrong hour, a series that stops early, an occurrence the organiser
/// moved that simply disappears.
final class EASRecurrenceTests: XCTestCase {

    // MARK: Building fixtures

    /// A 172-byte Win32 `TIME_ZONE_INFORMATION`, base64-encoded as the wire carries it.
    ///
    /// `bias` is in the Windows sense: minutes to add to local time to reach UTC, so UTC+3 is −180.
    private func timezoneBlob(
        bias: Int32,
        standardBias: Int32 = 0,
        daylightBias: Int32 = 0,
        standard: (month: Int, dayOfWeek: Int, day: Int, hour: Int)? = nil,
        daylight: (month: Int, dayOfWeek: Int, day: Int, hour: Int)? = nil
    ) -> String {
        var bytes = [UInt8](repeating: 0, count: 172)

        func writeInt32(_ value: Int32, at offset: Int) {
            let raw = UInt32(bitPattern: value)
            for i in 0..<4 { bytes[offset + i] = UInt8((raw >> (8 * UInt32(i))) & 0xFF) }
        }
        func writeUInt16(_ value: Int, at offset: Int) {
            bytes[offset] = UInt8(value & 0xFF)
            bytes[offset + 1] = UInt8((value >> 8) & 0xFF)
        }
        func writeSystemTime(_ time: (month: Int, dayOfWeek: Int, day: Int, hour: Int)?, at offset: Int) {
            guard let time else { return }   // all zeroes means "no transition"
            writeUInt16(0, at: offset)                  // year 0 = a relative rule
            writeUInt16(time.month, at: offset + 2)
            writeUInt16(time.dayOfWeek, at: offset + 4)
            writeUInt16(time.day, at: offset + 6)
            writeUInt16(time.hour, at: offset + 8)
        }

        writeInt32(bias, at: 0)
        writeSystemTime(standard, at: 68)
        writeInt32(standardBias, at: 84)
        writeSystemTime(daylight, at: 152)
        writeInt32(daylightBias, at: 168)

        return Data(bytes).base64EncodedString()
    }

    /// UTC+3 with no daylight saving — Moscow since 2014, and the zone this provider actually
    /// runs against.
    private var moscow: String { timezoneBlob(bias: -180) }

    /// UTC+1 standard, UTC+2 in summer, switching on the last Sunday of March and October.
    private var centralEuropean: String {
        timezoneBlob(
            bias: -60,
            standardBias: 0,
            daylightBias: -60,
            standard: (month: 10, dayOfWeek: 0, day: 5, hour: 3),
            daylight: (month: 3, dayOfWeek: 0, day: 5, hour: 2)
        )
    }

    private func series(
        start: String,
        end: String,
        timezone: String? = nil,
        recurrence: EASRecurrence?,
        exceptions: [EASException] = []
    ) -> EASCalendarItem {
        EASCalendarItem(
            serverId: "20:1",
            subject: "Standup",
            location: nil,
            start: EASDate.parse(start),
            end: EASDate.parse(end),
            isAllDay: false,
            organizerName: "Ivan",
            organizerEmail: "ivan@example.com",
            attendees: [],
            categories: [],
            uid: nil,
            meetingStatus: 1,
            responseType: nil,
            busyStatus: 2,
            bodyText: nil,
            bodyTruncated: false,
            onlineMeetingConfLink: nil,
            onlineMeetingExternalLink: nil,
            timezone: timezone,
            recurrence: recurrence,
            exceptions: exceptions
        )
    }

    private func window(_ from: String, _ to: String) -> DateInterval {
        DateInterval(start: EASDate.parse(from)!, end: EASDate.parse(to)!)
    }

    private func utcStamps(_ occurrences: [EASOccurrence]) -> [String] {
        occurrences.map { EASDate.format($0.start) }
    }

    // MARK: The timezone blob

    func testParsesAZoneWithoutDaylightSaving() throws {
        let zone = try XCTUnwrap(EASWindowsTimeZone.parse(base64: moscow))
        XCTAssertEqual(zone.bias, -180)
        XCTAssertFalse(zone.observesDaylightSaving)

        var summer = DateComponents()
        summer.year = 2026; summer.month = 7; summer.day = 1; summer.hour = 12
        XCTAssertEqual(zone.utcOffsetSeconds(forLocal: summer), 3 * 3600)

        var winter = summer
        winter.month = 1
        XCTAssertEqual(zone.utcOffsetSeconds(forLocal: winter), 3 * 3600,
                       "a zone without transitions keeps one offset all year")
    }

    func testParsesAZoneWithDaylightSaving() throws {
        let zone = try XCTUnwrap(EASWindowsTimeZone.parse(base64: centralEuropean))
        XCTAssertTrue(zone.observesDaylightSaving)

        var january = DateComponents()
        january.year = 2026; january.month = 1; january.day = 15; january.hour = 12
        XCTAssertEqual(zone.utcOffsetSeconds(forLocal: january), 3600)

        var july = january
        july.month = 7
        XCTAssertEqual(zone.utcOffsetSeconds(forLocal: july), 2 * 3600)
    }

    func testRejectsAnUnusableBlob() {
        XCTAssertNil(EASWindowsTimeZone.parse(base64: nil))
        XCTAssertNil(EASWindowsTimeZone.parse(base64: ""))
        XCTAssertNil(EASWindowsTimeZone.parse(base64: "not base64 at all!"))
        XCTAssertNil(EASWindowsTimeZone.parse(base64: Data([1, 2, 3]).base64EncodedString()),
                     "too short to be a TIME_ZONE_INFORMATION")
    }

    // MARK: Non-recurring items

    func testASingleAppointmentExpandsToItself() {
        let item = series(start: "20260915T070000Z", end: "20260915T073000Z", recurrence: nil)
        let result = EASRecurrenceExpander.expand(item, in: window("20260901T000000Z", "20261001T000000Z"))
        XCTAssertEqual(utcStamps(result), ["20260915T070000Z"])
    }

    func testASingleAppointmentOutsideTheWindowIsDropped() {
        let item = series(start: "20260915T070000Z", end: "20260915T073000Z", recurrence: nil)
        let result = EASRecurrenceExpander.expand(item, in: window("20261001T000000Z", "20261101T000000Z"))
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: Daily

    func testDailyEveryDay() {
        let item = series(
            start: "20260915T070000Z", end: "20260915T073000Z", timezone: moscow,
            recurrence: EASRecurrence(kind: .daily, interval: 1)
        )
        let result = EASRecurrenceExpander.expand(item, in: window("20260915T000000Z", "20260918T000000Z"))
        XCTAssertEqual(utcStamps(result), [
            "20260915T070000Z", "20260916T070000Z", "20260917T070000Z",
        ])
    }

    func testDailyWithAnInterval() {
        let item = series(
            start: "20260915T070000Z", end: "20260915T073000Z", timezone: moscow,
            recurrence: EASRecurrence(kind: .daily, interval: 3)
        )
        let result = EASRecurrenceExpander.expand(item, in: window("20260915T000000Z", "20260925T000000Z"))
        XCTAssertEqual(utcStamps(result), [
            "20260915T070000Z", "20260918T070000Z", "20260921T070000Z", "20260924T070000Z",
        ])
    }

    func testDailyCrossesAMonthBoundary() {
        let item = series(
            start: "20260929T070000Z", end: "20260929T073000Z", timezone: moscow,
            recurrence: EASRecurrence(kind: .daily, interval: 1)
        )
        let result = EASRecurrenceExpander.expand(item, in: window("20260929T000000Z", "20261003T000000Z"))
        XCTAssertEqual(utcStamps(result), [
            "20260929T070000Z", "20260930T070000Z", "20261001T070000Z", "20261002T070000Z",
        ])
    }

    // MARK: Weekly

    /// 15 September 2026 is a Tuesday. Mask 4 is Tuesday.
    func testWeeklyOnOneDay() {
        let item = series(
            start: "20260915T070000Z", end: "20260915T073000Z", timezone: moscow,
            recurrence: EASRecurrence(kind: .weekly, interval: 1, dayOfWeekMask: 4)
        )
        let result = EASRecurrenceExpander.expand(item, in: window("20260915T000000Z", "20261007T000000Z"))
        XCTAssertEqual(utcStamps(result), [
            "20260915T070000Z", "20260922T070000Z", "20260929T070000Z", "20261006T070000Z",
        ])
    }

    /// Mask 10 is Monday (2) plus Wednesday (8) — a rule producing two meetings a week.
    func testWeeklyOnSeveralDays() {
        let item = series(
            start: "20260914T070000Z", end: "20260914T073000Z", timezone: moscow,   // a Monday
            recurrence: EASRecurrence(kind: .weekly, interval: 1, dayOfWeekMask: 10)
        )
        let result = EASRecurrenceExpander.expand(item, in: window("20260914T000000Z", "20260928T000000Z"))
        XCTAssertEqual(utcStamps(result), [
            "20260914T070000Z", "20260916T070000Z",
            "20260921T070000Z", "20260923T070000Z",
        ])
    }

    func testWeeklyEveryOtherWeek() {
        let item = series(
            start: "20260915T070000Z", end: "20260915T073000Z", timezone: moscow,
            recurrence: EASRecurrence(kind: .weekly, interval: 2, dayOfWeekMask: 4)
        )
        let result = EASRecurrenceExpander.expand(item, in: window("20260915T000000Z", "20261014T000000Z"))
        XCTAssertEqual(utcStamps(result), [
            "20260915T070000Z", "20260929T070000Z", "20261013T070000Z",
        ])
    }

    /// The week a series starts in also contains days before it began; those are not occurrences.
    func testWeeklyDoesNotEmitBeforeTheSeriesStart() {
        let item = series(
            start: "20260916T070000Z", end: "20260916T073000Z", timezone: moscow,   // Wednesday
            recurrence: EASRecurrence(kind: .weekly, interval: 1, dayOfWeekMask: 10) // Mon + Wed
        )
        let result = EASRecurrenceExpander.expand(item, in: window("20260901T000000Z", "20260925T000000Z"))
        XCTAssertEqual(utcStamps(result).first, "20260916T070000Z",
                       "the Monday of the opening week predates the series")
    }

    // MARK: Monthly

    func testMonthlyOnAFixedDay() {
        let item = series(
            start: "20260115T070000Z", end: "20260115T073000Z", timezone: moscow,
            recurrence: EASRecurrence(kind: .monthlyByDay, interval: 1, dayOfMonth: 15)
        )
        let result = EASRecurrenceExpander.expand(item, in: window("20260101T000000Z", "20260415T000000Z"))
        XCTAssertEqual(utcStamps(result), [
            "20260115T070000Z", "20260215T070000Z", "20260315T070000Z",
        ])
    }

    /// The 31st does not exist in every month. Rolling into the 1st of the next one would invent
    /// a meeting that Exchange does not have; the month is skipped instead.
    func testMonthlyOnTheThirtyFirstSkipsShortMonths() {
        let item = series(
            start: "20260131T070000Z", end: "20260131T073000Z", timezone: moscow,
            recurrence: EASRecurrence(kind: .monthlyByDay, interval: 1, dayOfMonth: 31)
        )
        let result = EASRecurrenceExpander.expand(item, in: window("20260101T000000Z", "20260501T000000Z"))
        XCTAssertEqual(utcStamps(result), [
            "20260131T070000Z", "20260331T070000Z",
        ], "February and April have no 31st")
    }

    /// "The last Friday of the month". Mask 32 is Friday, week 5 means last.
    func testMonthlyOnTheLastWeekday() {
        let item = series(
            start: "20260130T070000Z", end: "20260130T073000Z", timezone: moscow,
            recurrence: EASRecurrence(
                kind: .monthlyByWeekday, interval: 1, dayOfWeekMask: 32, weekOfMonth: 5
            )
        )
        let result = EASRecurrenceExpander.expand(item, in: window("20260101T000000Z", "20260401T000000Z"))
        XCTAssertEqual(utcStamps(result), [
            "20260130T070000Z", "20260227T070000Z", "20260327T070000Z",
        ])
    }

    /// Mask 62 is every weekday, so this is "the first working day of the month" — not "the
    /// first Monday". Reading the mask as a single day is the usual way this goes wrong.
    func testMonthlyOnTheFirstWeekdayUsesTheWholeMask() {
        let item = series(
            start: "20260101T070000Z", end: "20260101T073000Z", timezone: moscow,
            recurrence: EASRecurrence(
                kind: .monthlyByWeekday, interval: 1, dayOfWeekMask: 62, weekOfMonth: 1
            )
        )
        let result = EASRecurrenceExpander.expand(item, in: window("20260101T000000Z", "20260401T000000Z"))
        // 1 Jan 2026 is a Thursday; 1 Feb is a Sunday so February starts on Monday the 2nd;
        // 1 Mar is a Sunday so March starts on Monday the 2nd.
        XCTAssertEqual(utcStamps(result), [
            "20260101T070000Z", "20260202T070000Z", "20260302T070000Z",
        ])
    }

    // MARK: Yearly

    func testYearlyOnAFixedDate() {
        let item = series(
            start: "20260315T070000Z", end: "20260315T073000Z", timezone: moscow,
            recurrence: EASRecurrence(kind: .yearlyByDate, interval: 1, dayOfMonth: 15, monthOfYear: 3)
        )
        let result = EASRecurrenceExpander.expand(item, in: window("20260101T000000Z", "20290101T000000Z"))
        XCTAssertEqual(utcStamps(result), [
            "20260315T070000Z", "20270315T070000Z", "20280315T070000Z",
        ])
    }

    // MARK: Limits

    func testStopsAtTheUntilDate() {
        let item = series(
            start: "20260915T070000Z", end: "20260915T073000Z", timezone: moscow,
            recurrence: EASRecurrence(
                kind: .daily, interval: 1, until: EASDate.parse("20260917T235959Z")
            )
        )
        let result = EASRecurrenceExpander.expand(item, in: window("20260915T000000Z", "20261001T000000Z"))
        XCTAssertEqual(utcStamps(result), [
            "20260915T070000Z", "20260916T070000Z", "20260917T070000Z",
        ])
    }

    func testStopsAtTheOccurrenceCount() {
        let item = series(
            start: "20260915T070000Z", end: "20260915T073000Z", timezone: moscow,
            recurrence: EASRecurrence(kind: .daily, interval: 1, occurrences: 2)
        )
        let result = EASRecurrenceExpander.expand(item, in: window("20260915T000000Z", "20261001T000000Z"))
        XCTAssertEqual(utcStamps(result), ["20260915T070000Z", "20260916T070000Z"])
    }

    /// Occurrences before the displayed window still consume the count — the limit is on the
    /// series, not on what happens to be visible.
    func testOccurrenceCountIncludesOnesBeforeTheWindow() {
        let item = series(
            start: "20260901T070000Z", end: "20260901T073000Z", timezone: moscow,
            recurrence: EASRecurrence(kind: .daily, interval: 1, occurrences: 3)
        )
        let result = EASRecurrenceExpander.expand(item, in: window("20260902T120000Z", "20261001T000000Z"))
        XCTAssertEqual(utcStamps(result), ["20260903T070000Z"],
                       "three occurrences total, only the third is inside the window")
    }

    /// A rule with no end is legal and common — "every weekday, forever". Without a ceiling this
    /// runs until the process is killed, on the synchronisation path.
    func testAnEndlessRuleIsCapped() {
        let item = series(
            start: "20260101T070000Z", end: "20260101T073000Z", timezone: moscow,
            recurrence: EASRecurrence(kind: .daily, interval: 1)
        )
        // A window a century wide would otherwise ask for ~36 500 occurrences.
        let result = EASRecurrenceExpander.expand(item, in: window("20260101T000000Z", "21260101T000000Z"))
        XCTAssertLessThanOrEqual(result.count, EASRecurrenceExpander.occurrenceCap)
        XCTAssertGreaterThan(result.count, 0)
    }

    // MARK: Exceptions

    func testDeletedOccurrenceDisappears() {
        let item = series(
            start: "20260915T070000Z", end: "20260915T073000Z", timezone: moscow,
            recurrence: EASRecurrence(kind: .daily, interval: 1),
            exceptions: [
                EASException(originalStart: EASDate.parse("20260916T070000Z")!, isDeleted: true)
            ]
        )
        let result = EASRecurrenceExpander.expand(item, in: window("20260915T000000Z", "20260918T000000Z"))
        XCTAssertEqual(utcStamps(result), ["20260915T070000Z", "20260917T070000Z"])
    }

    func testMovedOccurrenceKeepsItsIdentity() {
        let original = EASDate.parse("20260916T070000Z")!
        let item = series(
            start: "20260915T070000Z", end: "20260915T073000Z", timezone: moscow,
            recurrence: EASRecurrence(kind: .daily, interval: 1),
            exceptions: [
                EASException(
                    originalStart: original,
                    isDeleted: false,
                    start: EASDate.parse("20260916T140000Z"),
                    end: EASDate.parse("20260916T143000Z")
                )
            ]
        )
        let result = EASRecurrenceExpander.expand(item, in: window("20260915T000000Z", "20260918T000000Z"))
        let moved = try? XCTUnwrap(result.first { $0.exception != nil })

        XCTAssertEqual(moved?.start, EASDate.parse("20260916T140000Z"))
        // Identity stays with the slot the rule produced: the whole app keys events by id, and a
        // moved meeting is still the same meeting.
        XCTAssertEqual(moved?.originalStart, original)
    }

    func testModifiedOccurrenceOverridesOnlyWhatItStates() throws {
        let item = series(
            start: "20260915T070000Z", end: "20260915T073000Z", timezone: moscow,
            recurrence: EASRecurrence(kind: .daily, interval: 1),
            exceptions: [
                EASException(
                    originalStart: EASDate.parse("20260916T070000Z")!,
                    isDeleted: false,
                    subject: "Standup — extended"
                )
            ]
        )
        let events = EASCalendarMapper().events(
            from: item,
            in: window("20260915T000000Z", "20260918T000000Z"),
            accountID: UUID()
        )
        XCTAssertEqual(events.map(\.title), ["Standup", "Standup — extended", "Standup"])
        XCTAssertEqual(events[1].organizer, "Ivan", "unstated fields are inherited from the master")
    }

    /// The case that quietly loses meetings: an occurrence moved far enough that its original
    /// slot is no longer generated. Dropping it makes the meeting vanish with no trace.
    func testExceptionWithNoMatchingSlotIsStillShown() {
        let item = series(
            start: "20260915T070000Z", end: "20260915T073000Z", timezone: moscow,
            recurrence: EASRecurrence(
                kind: .daily, interval: 1, until: EASDate.parse("20260917T235959Z")
            ),
            exceptions: [
                EASException(
                    // A slot the rule never produces — the series ended before it.
                    originalStart: EASDate.parse("20260925T070000Z")!,
                    isDeleted: false,
                    start: EASDate.parse("20260925T090000Z"),
                    end: EASDate.parse("20260925T093000Z"),
                    subject: "Moved out of the series"
                )
            ]
        )
        let result = EASRecurrenceExpander.expand(item, in: window("20260915T000000Z", "20261001T000000Z"))
        XCTAssertTrue(
            utcStamps(result).contains("20260925T090000Z"),
            "an orphaned exception is still a real meeting on the calendar"
        )
    }

    // MARK: Daylight saving

    /// A weekly meeting repeats at a wall-clock time. Across a daylight transition that is a
    /// different instant — which is exactly what expanding in UTC would get wrong.
    func testWeeklyKeepsItsLocalTimeAcrossADaylightTransition() {
        // 10:00 Central European. In March that is 09:00 UTC; after the last Sunday of March,
        // 08:00 UTC.
        let item = series(
            start: "20260324T090000Z", end: "20260324T093000Z", timezone: centralEuropean,
            recurrence: EASRecurrence(kind: .weekly, interval: 1, dayOfWeekMask: 4)   // Tuesday
        )
        let result = EASRecurrenceExpander.expand(item, in: window("20260323T000000Z", "20260408T000000Z"))

        XCTAssertEqual(utcStamps(result), [
            "20260324T090000Z",   // before the change: UTC+1
            "20260331T080000Z",   // after: UTC+2, same 10:00 locally
            "20260407T080000Z",
        ])
    }

    func testWithoutDaylightSavingTheUTCTimeNeverShifts() {
        let item = series(
            start: "20260324T070000Z", end: "20260324T073000Z", timezone: moscow,
            recurrence: EASRecurrence(kind: .weekly, interval: 1, dayOfWeekMask: 4)
        )
        let result = EASRecurrenceExpander.expand(item, in: window("20260323T000000Z", "20260408T000000Z"))
        XCTAssertEqual(utcStamps(result), [
            "20260324T070000Z", "20260331T070000Z", "20260407T070000Z",
        ])
    }

    // MARK: Event identity

    func testOccurrencesGetDistinctStableIds() {
        let item = series(
            start: "20260915T070000Z", end: "20260915T073000Z", timezone: moscow,
            recurrence: EASRecurrence(kind: .daily, interval: 1)
        )
        let mapper = EASCalendarMapper()
        let accountID = UUID()
        let first = mapper.events(from: item, in: window("20260915T000000Z", "20260918T000000Z"), accountID: accountID)
        let second = mapper.events(from: item, in: window("20260915T000000Z", "20260918T000000Z"), accountID: accountID)

        XCTAssertEqual(first.map(\.id), second.map(\.id), "ids must not drift between syncs")
        XCTAssertEqual(Set(first.map(\.id)).count, first.count, "each occurrence is distinct")
        XCTAssertTrue(first.allSatisfy { $0.changeKey == "20:1" }, "RSVP stays available")
    }

    // MARK: Pre-expansion filtering

    /// The filter exists for performance, but an error here loses a meeting, so it is tested more
    /// rigorously than the optimization itself might otherwise warrant.
    func testPastSingleIsRejectedCheaply() {
        let item = series(start: "20200101T070000Z", end: "20200101T080000Z", recurrence: nil)
        XCTAssertFalse(
            EASRecurrenceExpander.mayProduceOccurrences(item, in: window("20260901T000000Z", "20261001T000000Z"))
        )
    }

    func testSingleInsideTheWindowSurvives() {
        let item = series(start: "20260915T070000Z", end: "20260915T080000Z", recurrence: nil)
        XCTAssertTrue(
            EASRecurrenceExpander.mayProduceOccurrences(item, in: window("20260901T000000Z", "20261001T000000Z"))
        )
    }

    /// A meeting that began before the window and continues into it is still a meeting.
    func testSingleStraddlingTheWindowStartSurvives() {
        let item = series(start: "20260831T220000Z", end: "20260901T020000Z", recurrence: nil)
        XCTAssertTrue(
            EASRecurrenceExpander.mayProduceOccurrences(item, in: window("20260901T000000Z", "20261001T000000Z"))
        )
    }

    func testSeriesEndedBeforeTheWindowIsRejected() {
        let item = series(
            start: "20200101T070000Z", end: "20200101T080000Z", timezone: moscow,
            recurrence: EASRecurrence(kind: .daily, interval: 1, until: EASDate.parse("20200601T000000Z"))
        )
        XCTAssertFalse(
            EASRecurrenceExpander.mayProduceOccurrences(item, in: window("20260901T000000Z", "20261001T000000Z"))
        )
    }

    func testSeriesStartingAfterTheWindowIsRejected() {
        let item = series(
            start: "20270101T070000Z", end: "20270101T080000Z", timezone: moscow,
            recurrence: EASRecurrence(kind: .daily, interval: 1)
        )
        XCTAssertFalse(
            EASRecurrenceExpander.mayProduceOccurrences(item, in: window("20260901T000000Z", "20261001T000000Z"))
        )
    }

    /// An unbounded series from the past reaches the window and must not be filtered out.
    func testEndlessSeriesFromThePastSurvives() {
        let item = series(
            start: "20200101T070000Z", end: "20200101T080000Z", timezone: moscow,
            recurrence: EASRecurrence(kind: .weekly, interval: 1, dayOfWeekMask: 4)
        )
        XCTAssertTrue(
            EASRecurrenceExpander.mayProduceOccurrences(item, in: window("20260901T000000Z", "20261001T000000Z"))
        )
    }

    /// The most dangerous case: a series ended long ago, but one occurrence moved into the window.
    /// Filtering by the rule would discard a meeting that actually exists.
    func testMovedOccurrenceRescuesAnOtherwiseRejectedSeries() {
        let item = series(
            start: "20200101T070000Z", end: "20200101T080000Z", timezone: moscow,
            recurrence: EASRecurrence(kind: .daily, interval: 1, until: EASDate.parse("20200601T000000Z")),
            exceptions: [
                EASException(
                    originalStart: EASDate.parse("20200301T070000Z")!,
                    isDeleted: false,
                    start: EASDate.parse("20260915T090000Z"),
                    end: EASDate.parse("20260915T100000Z")
                )
            ]
        )
        let w = window("20260901T000000Z", "20261001T000000Z")
        XCTAssertTrue(EASRecurrenceExpander.mayProduceOccurrences(item, in: w))
        XCTAssertEqual(utcStamps(EASRecurrenceExpander.expand(item, in: w)), ["20260915T090000Z"])
    }

    /// A deleted occurrence is not a reason to retain a long-finished series.
    func testDeletedExceptionDoesNotRescueASeries() {
        let item = series(
            start: "20200101T070000Z", end: "20200101T080000Z", timezone: moscow,
            recurrence: EASRecurrence(kind: .daily, interval: 1, until: EASDate.parse("20200601T000000Z")),
            exceptions: [
                EASException(originalStart: EASDate.parse("20260915T070000Z")!, isDeleted: true)
            ]
        )
        XCTAssertFalse(
            EASRecurrenceExpander.mayProduceOccurrences(item, in: window("20260901T000000Z", "20261001T000000Z"))
        )
    }

    func testItemWithoutTimesIsRejected() {
        let item = series(start: "20260915T070000Z", end: "20260915T080000Z", recurrence: nil)
        var broken = item
        broken.start = nil
        XCTAssertFalse(
            EASRecurrenceExpander.mayProduceOccurrences(broken, in: window("20260901T000000Z", "20261001T000000Z"))
        )
    }
}
