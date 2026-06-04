import XCTest
@testable import OWAWidget

@MainActor
final class MeetingSearchPolicyTests: XCTestCase {
    private let day0 = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - matches: per-field

    func testMatchesByTitle() {
        let e = makeEvent(id: "a", title: "Quarterly Standup")
        XCTAssertTrue(PopoverView.MeetingSearchPolicy.matches(e, query: "standup"))
        XCTAssertFalse(PopoverView.MeetingSearchPolicy.matches(e, query: "review"))
    }

    func testMatchesByOrganizer() {
        let e = makeEvent(id: "a", title: "Sync", organizer: "Alice Johnson")
        XCTAssertTrue(PopoverView.MeetingSearchPolicy.matches(e, query: "johnson"))
    }

    func testMatchesByAttendee() {
        let e = makeEvent(id: "a", title: "Sync", attendees: ["Bob Smith", "Carol White"])
        XCTAssertTrue(PopoverView.MeetingSearchPolicy.matches(e, query: "carol"))
    }

    func testMatchesByLocation() {
        let e = makeEvent(id: "a", title: "Sync", location: "Room 42, Building B")
        XCTAssertTrue(PopoverView.MeetingSearchPolicy.matches(e, query: "building"))
    }

    func testMatchesByBodyPreview() {
        let e = makeEvent(id: "a", title: "Sync", bodyPreview: "Discuss the migration roadmap")
        XCTAssertTrue(PopoverView.MeetingSearchPolicy.matches(e, query: "roadmap"))
    }

    // MARK: - matches: normalization

    func testMatchesIsCaseInsensitive() {
        let e = makeEvent(id: "a", title: "Standup")
        XCTAssertTrue(PopoverView.MeetingSearchPolicy.matches(e, query: "STANDUP"))
    }

    func testMatchesTransliteratesCyrillicQueryToLatinHaystack() {
        // Reuses OWAPersonSearchTokenMatch: Latin "ivan" should match Cyrillic "Иван".
        let e = makeEvent(id: "a", title: "Sync", organizer: "Иван Петров")
        XCTAssertTrue(PopoverView.MeetingSearchPolicy.matches(e, query: "ivan"))
    }

    // MARK: - matches: word-boundary (no mid-word false positives)

    func testShortTokenDoesNotMatchMidWordTransliteration() {
        // "Михаил" → "mikhail" contains "ai" mid-word; must NOT match.
        let e = makeEvent(id: "a", title: "Дорожная карта", organizer: "Чернов Михаил Иванович")
        XCTAssertFalse(PopoverView.MeetingSearchPolicy.matches(e, query: "ai"))
    }

    func testShortTokenMatchesWordStartInLatinAndCyrillic() {
        let latin = makeEvent(id: "lat", title: "AI ассистент Митя")
        let cyrillic = makeEvent(id: "cyr", title: "АИ ассистент Митя")
        XCTAssertTrue(PopoverView.MeetingSearchPolicy.matches(latin, query: "ai"))
        XCTAssertTrue(PopoverView.MeetingSearchPolicy.matches(cyrillic, query: "ai"))
    }

    func testTokenMatchesWordPrefixForIncrementalTyping() {
        let e = makeEvent(id: "a", title: "Планирование спринта")
        XCTAssertTrue(PopoverView.MeetingSearchPolicy.matches(e, query: "план"))
    }

    func testQueryPunctuationTokenizesLikeFields() {
        // Query and fields must split on punctuation the same way: "O'Brien" / "Jean-Pierre"
        // would otherwise tokenize asymmetrically and never match.
        let apostrophe = makeEvent(id: "a", title: "Sync with O'Brien")
        XCTAssertTrue(PopoverView.MeetingSearchPolicy.matches(apostrophe, query: "o'brien"))

        let hyphen = makeEvent(id: "b", title: "Jean-Pierre review")
        XCTAssertTrue(PopoverView.MeetingSearchPolicy.matches(hyphen, query: "jean-pierre"))
    }

    // MARK: - matches: tokens spanning different fields

    func testTokensCanSpanDifferentFields() {
        let e = makeEvent(
            id: "a",
            title: "Planning",
            attendees: ["Carol White"],
            location: "Room 42"
        )
        // Each token resolves in a different field (title / attendee / location).
        XCTAssertTrue(PopoverView.MeetingSearchPolicy.matches(e, query: "planning carol 42"))
        // One token absent from every field → no match (AND semantics).
        XCTAssertFalse(PopoverView.MeetingSearchPolicy.matches(e, query: "planning carol 99"))
    }

    // MARK: - matches: AND across tokens

    func testMatchesRequiresAllTokens() {
        let e = makeEvent(id: "a", title: "Standup", organizer: "Ivan Petrov")
        XCTAssertTrue(PopoverView.MeetingSearchPolicy.matches(e, query: "standup ivan"))
        XCTAssertFalse(PopoverView.MeetingSearchPolicy.matches(e, query: "standup review"))
    }

    // MARK: - filter

    func testFilterEmptyQueryReturnsNothing() {
        let e = makeEvent(id: "a", title: "Standup")
        XCTAssertTrue(PopoverView.MeetingSearchPolicy.filter([e], query: "").isEmpty)
        XCTAssertTrue(PopoverView.MeetingSearchPolicy.filter([e], query: "   ").isEmpty)
    }

    func testFilterIncludesCancelledEvents() {
        let cancelled = makeEvent(id: "c", title: "Cancelled: Standup", isCancelled: true)
        let result = PopoverView.MeetingSearchPolicy.filter([cancelled], query: "standup")
        XCTAssertEqual(result.map(\.id), ["c"])
    }

    func testFilterIncludesAllDayEvents() {
        let allDay = makeEvent(id: "ad", title: "Standup offsite", isAllDay: true)
        let result = PopoverView.MeetingSearchPolicy.filter([allDay], query: "offsite")
        XCTAssertEqual(result.map(\.id), ["ad"])
    }

    func testFilterSortsByStartDateAscending() {
        let later = makeEvent(id: "later", title: "Standup", start: day0.addingTimeInterval(3 * 3600))
        let earlier = makeEvent(id: "earlier", title: "Standup", start: day0.addingTimeInterval(1 * 3600))
        let result = PopoverView.MeetingSearchPolicy.filter([later, earlier], query: "standup")
        XCTAssertEqual(result.map(\.id), ["earlier", "later"])
    }

    // MARK: - groupByDay

    func testGroupByDaySplitsAcrossDaysInChronologicalOrder() {
        let calendar = Calendar(identifier: .gregorian)
        let day1 = makeEvent(id: "d1", title: "Standup", start: day0.addingTimeInterval(9 * 3600))
        let day2a = makeEvent(id: "d2a", title: "Standup", start: day0.addingTimeInterval(24 * 3600 + 9 * 3600))
        let day2b = makeEvent(id: "d2b", title: "Standup", start: day0.addingTimeInterval(24 * 3600 + 14 * 3600))

        let groups = PopoverView.MeetingSearchPolicy.groupByDay([day2b, day1, day2a], calendar: calendar)

        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].events.map(\.id), ["d1"])
        XCTAssertEqual(groups[1].events.map(\.id), ["d2a", "d2b"])
        XCTAssertTrue(groups[0].date < groups[1].date)
    }

    // MARK: - Helpers

    private func makeEvent(
        id: String,
        title: String,
        start: Date? = nil,
        organizer: String? = nil,
        attendees: [String] = [],
        location: String? = nil,
        bodyPreview: String? = nil,
        isAllDay: Bool = false,
        isCancelled: Bool = false
    ) -> CalendarEvent {
        let s = start ?? day0
        return CalendarEvent(
            id: id,
            title: title,
            startDate: s,
            endDate: s.addingTimeInterval(30 * 60),
            location: location,
            bodyPreview: bodyPreview,
            joinURL: nil,
            platform: .teams,
            isAllDay: isAllDay,
            organizer: organizer,
            attendees: attendees,
            accountID: UUID(),
            isCancelled: isCancelled
        )
    }
}
