import XCTest
@testable import OWAWidget

/// Parsing an appointment off the wire and turning it into a `CalendarEvent`.
final class EASCalendarMappingTests: XCTestCase {

    // MARK: Dates

    func testParsesTheCompactCalendarFormat() throws {
        let date = try XCTUnwrap(EASDate.parse("20260915T070000Z"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)

        XCTAssertEqual(parts.year, 2026)
        XCTAssertEqual(parts.month, 9)
        XCTAssertEqual(parts.day, 15)
        XCTAssertEqual(parts.hour, 7)
        XCTAssertEqual(parts.minute, 0)
        XCTAssertEqual(parts.second, 0)
    }

    func testParsesTheExtendedFormatToo() {
        XCTAssertNotNil(EASDate.parse("2026-09-15T07:00:00Z"))
        XCTAssertNotNil(EASDate.parse("2026-09-15T07:00:00.000Z"))
    }

    func testFormatRoundTrips() throws {
        let original = try XCTUnwrap(EASDate.parse("20260915T070000Z"))
        XCTAssertEqual(EASDate.format(original), "20260915T070000Z")
    }

    func testRejectsMalformedTimestamps() {
        // Silently returning `nil` here is fine — the mapper drops the item — but returning a
        // *wrong* date would place a meeting at the wrong time, so the shape checks are strict.
        XCTAssertNil(EASDate.parse(""))
        XCTAssertNil(EASDate.parse(nil))
        XCTAssertNil(EASDate.parse("20260915"))
        XCTAssertNil(EASDate.parse("20260915T070000"))     // no zone marker
        XCTAssertNil(EASDate.parse("not a date at all!!"))
    }

    // MARK: Parsing an item

    private func applicationData(_ build: (WBXMLWriter) -> Void) throws -> WBNode {
        let writer = WBXMLWriter()
        writer.node(AS.applicationData) { build(writer) }
        let tree = try WBXMLReader.parse(writer.data)
        return try XCTUnwrap(tree.first(AS.applicationData))
    }

    func testParsesAFullAppointment() throws {
        let data = try applicationData { w in
            w.leaf(CAL.subject, "Ревью архитектуры")
            w.leaf(CAL.location, "Переговорная 3")
            w.leaf(CAL.startTime, "20260915T070000Z")
            w.leaf(CAL.endTime, "20260915T080000Z")
            w.leaf(CAL.allDayEvent, "0")
            w.leaf(CAL.organizerName, "Иван Петров")
            w.leaf(CAL.organizerEmail, "ivan@example.com")
            w.leaf(CAL.meetingStatus, "3")
            w.leaf(CAL.responseType, "3")
            w.leaf(CAL.busyStatus, "2")
            w.leaf(CAL.uid, "040000008200E0")
            w.node(CAL.categories) {
                w.leaf(CAL.category, "Работа")
                w.leaf(CAL.category, "Важное")
            }
            w.node(CAL.attendees) {
                w.node(CAL.attendee) {
                    w.leaf(CAL.email, "anna@example.com")
                    w.leaf(CAL.name, "Анна")
                    w.leaf(CAL.attendeeType, "1")
                    w.leaf(CAL.attendeeStatus, "3")
                }
            }
            w.node(ASB.body) {
                w.leaf(ASB.type, "1")
                w.leaf(ASB.data, "Обсуждаем план")
            }
        }

        let item = try XCTUnwrap(EASCalendarItem(serverId: "20:7", applicationData: data))

        XCTAssertEqual(item.subject, "Ревью архитектуры")
        XCTAssertEqual(item.location, "Переговорная 3")
        XCTAssertEqual(item.organizerName, "Иван Петров")
        XCTAssertEqual(item.categories, ["Работа", "Важное"])
        XCTAssertEqual(item.attendees.first?.name, "Анна")
        XCTAssertEqual(item.attendees.first?.status, 3)
        XCTAssertEqual(item.bodyText, "Обсуждаем план")
        XCTAssertFalse(item.isRecurring)
        XCTAssertFalse(item.isAllDay)
    }

    /// `MeetingStatus` is a bit field, and reading it as an enum gets cancellation wrong.
    /// Bit 0 — it is a meeting; bit 1 — received rather than organised; bit 2 — cancelled.
    func testMeetingStatusBitsAreDecodedIndependently() throws {
        func item(status: String) throws -> EASCalendarItem {
            let data = try applicationData { w in
                w.leaf(CAL.subject, "X")
                w.leaf(CAL.startTime, "20260915T070000Z")
                w.leaf(CAL.endTime, "20260915T080000Z")
                w.leaf(CAL.meetingStatus, status)
            }
            return try XCTUnwrap(EASCalendarItem(serverId: "20:1", applicationData: data))
        }

        let appointment = try item(status: "0")
        XCTAssertFalse(appointment.isMeeting)
        XCTAssertFalse(appointment.isOrganizer, "a plain appointment has no organiser role")
        XCTAssertFalse(appointment.isCancelled)

        let organised = try item(status: "1")
        XCTAssertTrue(organised.isMeeting)
        XCTAssertTrue(organised.isOrganizer)
        XCTAssertFalse(organised.isCancelled)

        let received = try item(status: "3")
        XCTAssertTrue(received.isMeeting)
        XCTAssertFalse(received.isOrganizer)
        XCTAssertFalse(received.isCancelled)

        let cancelledByMe = try item(status: "5")
        XCTAssertTrue(cancelledByMe.isCancelled)
        XCTAssertTrue(cancelledByMe.isOrganizer)

        let cancelledByThem = try item(status: "7")
        XCTAssertTrue(cancelledByThem.isCancelled)
        XCTAssertFalse(cancelledByThem.isOrganizer)
    }

    func testDetectsARecurringSeries() throws {
        let data = try applicationData { w in
            w.leaf(CAL.subject, "Weekly")
            w.leaf(CAL.startTime, "20260915T070000Z")
            w.leaf(CAL.endTime, "20260915T073000Z")
            w.node(CAL.recurrence) {
                w.leaf(CAL.type, "1")
                w.leaf(CAL.interval, "1")
                w.leaf(CAL.dayOfWeek, "2")
            }
        }
        let item = try XCTUnwrap(EASCalendarItem(serverId: "20:9", applicationData: data))
        XCTAssertTrue(item.isRecurring, "series must be recognised so they are not shown as singles")
    }

    func testRejectsAnItemWithoutAServerId() throws {
        let data = try applicationData { w in w.leaf(CAL.subject, "X") }
        XCTAssertNil(EASCalendarItem(serverId: "", applicationData: data))
    }

    // MARK: Mapping to CalendarEvent

    private func item(
        serverId: String = "20:1",
        subject: String? = "Standup",
        start: String? = "20260915T070000Z",
        end: String? = "20260915T073000Z",
        location: String? = nil,
        body: String? = nil,
        confLink: String? = nil,
        meetingStatus: Int? = 1,
        responseType: Int? = nil
    ) -> EASCalendarItem {
        EASCalendarItem(
            serverId: serverId,
            subject: subject,
            location: location,
            start: EASDate.parse(start),
            end: EASDate.parse(end),
            isAllDay: false,
            organizerName: "Ivan",
            organizerEmail: "ivan@example.com",
            attendees: [EASAttendee(name: "Anna", email: "anna@example.com", type: 1, status: 3)],
            categories: [],
            uid: nil,
            meetingStatus: meetingStatus,
            responseType: responseType,
            busyStatus: 2,
            bodyText: body,
            bodyTruncated: false,
            onlineMeetingConfLink: confLink,
            onlineMeetingExternalLink: nil,
            timezone: nil,
            recurrence: nil,
            exceptions: []
        )
    }

    func testMapsTheBasics() throws {
        let event = try XCTUnwrap(EASCalendarMapper().event(from: item(), accountID: UUID()))
        XCTAssertEqual(event.title, "Standup")
        XCTAssertEqual(event.organizer, "Ivan")
        XCTAssertEqual(event.attendees, ["Anna"])
        XCTAssertEqual(event.responseType, .organizer, "MeetingStatus=1 means the user organised it")
    }

    /// `CalendarService` deduplicates, patches RSVP optimistically and caches details all by
    /// event id. An id that changed between syncs would break every one of those quietly.
    func testEventIdIsTheServerIdAndIsStable() throws {
        let mapper = EASCalendarMapper()
        let first = try XCTUnwrap(mapper.event(from: item(), accountID: UUID()))
        let second = try XCTUnwrap(mapper.event(from: item(subject: "Renamed"), accountID: UUID()))
        XCTAssertEqual(first.id, "20:1")
        XCTAssertEqual(first.id, second.id, "a renamed meeting is still the same meeting")
    }

    func testOccurrenceIdsAreKeyedOnTheOriginalStart() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let id = EASCalendarMapper.eventID(serverId: "20:9", originalStart: start)
        XCTAssertEqual(id, "20:9|1800000000")
        // Keyed on the original start, not the effective one, so moving a single occurrence of a
        // series does not give it a new identity.
        XCTAssertEqual(EASCalendarMapper.eventID(serverId: "20:9", originalStart: start), id)
    }

    /// The RSVP buttons are gated on `changeKey != nil`. ActiveSync has no change key, so the
    /// ServerId stands in — it is opaque to the UI and is what `respondToMeeting` needs back.
    func testChangeKeyCarriesTheServerId() throws {
        let event = try XCTUnwrap(EASCalendarMapper().event(from: item(), accountID: UUID()))
        XCTAssertEqual(event.changeKey, "20:1")
    }

    func testResponseTypeMapping() {
        XCTAssertEqual(EASCalendarMapper.responseType(for: item(meetingStatus: 3, responseType: 2)), .tentative)
        XCTAssertEqual(EASCalendarMapper.responseType(for: item(meetingStatus: 3, responseType: 3)), .accepted)
        XCTAssertEqual(EASCalendarMapper.responseType(for: item(meetingStatus: 3, responseType: 4)), .declined)
        XCTAssertEqual(EASCalendarMapper.responseType(for: item(meetingStatus: 3, responseType: 5)), .notResponded)
        XCTAssertEqual(EASCalendarMapper.responseType(for: item(meetingStatus: 3, responseType: nil)), .notResponded)
        // Organising wins over whatever ResponseType says.
        XCTAssertEqual(EASCalendarMapper.responseType(for: item(meetingStatus: 1, responseType: 4)), .organizer)
    }

    func testDropsItemsThatCannotBecomeEvents() {
        let mapper = EASCalendarMapper()
        XCTAssertNil(mapper.event(from: item(subject: nil), accountID: UUID()))
        XCTAssertNil(mapper.event(from: item(start: nil), accountID: UUID()))
        XCTAssertNil(mapper.event(from: item(end: nil), accountID: UUID()))
    }

    func testZeroLengthAppointmentGetsAVisibleDuration() throws {
        let sameMoment = item(start: "20260915T070000Z", end: "20260915T070000Z")
        let event = try XCTUnwrap(EASCalendarMapper().event(from: sameMoment, accountID: UUID()))
        XCTAssertGreaterThan(event.endDate, event.startDate)
    }

    func testPreviewIsCollapsedAndCapped() throws {
        let long = String(repeating: "слово ", count: 200)
        let event = try XCTUnwrap(EASCalendarMapper().event(from: item(body: long), accountID: UUID()))
        let preview = try XCTUnwrap(event.bodyPreview)
        XCTAssertLessThanOrEqual(preview.count, 255)
        XCTAssertFalse(preview.contains("\n"))
    }

    func testJoinURLPrefersTheDedicatedFieldOverTheLocation() throws {
        let both = item(
            location: "https://meet.example.com/from-location",
            confLink: "https://meet.example.com/from-field"
        )
        let event = try XCTUnwrap(EASCalendarMapper().event(from: both, accountID: UUID()))
        XCTAssertEqual(event.joinURL?.absoluteString, "https://meet.example.com/from-field")
    }

    /// Location and body are scanned by `MeetingURLDetector`, which recognises known
    /// conferencing platforms rather than any link — a bare URL in an agenda is usually a
    /// document, not a call.
    func testJoinURLFallsBackToLocationThenBody() throws {
        let mapper = EASCalendarMapper()
        let teams = "https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc"

        let fromLocation = try XCTUnwrap(
            mapper.event(from: item(location: teams), accountID: UUID())
        )
        XCTAssertEqual(fromLocation.joinURL?.absoluteString, teams)
        XCTAssertEqual(fromLocation.platform, .teams)

        let fromBody = try XCTUnwrap(
            mapper.event(from: item(body: "Join at \(teams) please"), accountID: UUID())
        )
        XCTAssertEqual(fromBody.joinURL?.absoluteString, teams)
    }

    /// The dedicated ActiveSync field is trusted as a join link whatever the host, because the
    /// organiser put it there on purpose. Scanning free text is the part that stays conservative.
    func testDedicatedFieldAcceptsAnyHTTPSLinkAsGeneric() throws {
        let event = try XCTUnwrap(
            EASCalendarMapper().event(
                from: item(confLink: "https://meet.example.com/from-field"),
                accountID: UUID()
            )
        )
        XCTAssertEqual(event.joinURL?.absoluteString, "https://meet.example.com/from-field")
        XCTAssertEqual(event.platform, .generic)
    }

    func testNoJoinURLWhenThereIsNoLink() throws {
        let mapper = EASCalendarMapper()

        let room = try XCTUnwrap(mapper.event(from: item(location: "Переговорная 3"), accountID: UUID()))
        XCTAssertNil(room.joinURL)

        // A plain link in the agenda is not a call.
        let document = try XCTUnwrap(
            mapper.event(from: item(body: "Материалы: https://wiki.example.com/page"), accountID: UUID())
        )
        XCTAssertNil(document.joinURL)
    }
}
