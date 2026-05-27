import XCTest
@testable import OWAWidget

final class GlobalHotkeyJoinActionTests: XCTestCase {
    private let accountID = UUID()

    func testCandidatesIncludeOngoingAndNearFutureMeetings() {
        let now = Date()
        let ongoing = makeEvent(
            id: "ongoing",
            start: now.addingTimeInterval(-5 * 60),
            end: now.addingTimeInterval(10 * 60)
        )
        let nearFuture = makeEvent(
            id: "near-future",
            start: now.addingTimeInterval(90),
            end: now.addingTimeInterval(30 * 60)
        )
        let farFuture = makeEvent(
            id: "far-future",
            start: now.addingTimeInterval(3 * 60),
            end: now.addingTimeInterval(40 * 60)
        )

        let result = GlobalHotkeyJoinAction.candidates(from: [farFuture, nearFuture, ongoing], now: now)

        XCTAssertEqual(result.map(\.id), ["ongoing", "near-future"])
    }

    func testCandidatesExcludeAllDayCancelledAndNoLinkMeetings() {
        let now = Date()
        let noLink = makeEvent(
            id: "no-link",
            start: now.addingTimeInterval(-60),
            end: now.addingTimeInterval(600),
            joinURL: nil
        )
        let allDay = makeEvent(
            id: "all-day",
            start: now.addingTimeInterval(-3600),
            end: now.addingTimeInterval(3600),
            isAllDay: true
        )
        let cancelled = makeEvent(
            id: "cancelled",
            start: now.addingTimeInterval(-60),
            end: now.addingTimeInterval(600),
            isCancelled: true
        )

        let result = GlobalHotkeyJoinAction.candidates(from: [noLink, allDay, cancelled], now: now)

        XCTAssertTrue(result.isEmpty)
    }

    func testCandidatesIncludeMeetingStartingExactlyInTwoMinutes() {
        let now = Date()
        let atBoundary = makeEvent(
            id: "two-min",
            start: now.addingTimeInterval(2 * 60),
            end: now.addingTimeInterval(30 * 60)
        )

        let result = GlobalHotkeyJoinAction.candidates(from: [atBoundary], now: now)

        XCTAssertEqual(result.map(\.id), ["two-min"])
    }

    func testCandidatesExcludeMeetingStartingJustAfterTwoMinutes() {
        let now = Date()
        let afterBoundary = makeEvent(
            id: "two-min-plus",
            start: now.addingTimeInterval(2 * 60 + 1),
            end: now.addingTimeInterval(30 * 60)
        )

        let result = GlobalHotkeyJoinAction.candidates(from: [afterBoundary], now: now)

        XCTAssertTrue(result.isEmpty)
    }

    func testCandidatesExcludeEndedMeeting() {
        let now = Date()
        let ended = makeEvent(
            id: "ended",
            start: now.addingTimeInterval(-60 * 60),
            end: now.addingTimeInterval(-5 * 60)
        )

        let result = GlobalHotkeyJoinAction.candidates(from: [ended], now: now)

        XCTAssertTrue(result.isEmpty)
    }

    private func makeEvent(
        id: String,
        start: Date,
        end: Date,
        joinURL: URL? = URL(string: "https://meet.example/\(UUID().uuidString)"),
        isAllDay: Bool = false,
        isCancelled: Bool = false
    ) -> CalendarEvent {
        CalendarEvent(
            id: id,
            title: "Event \(id)",
            startDate: start,
            endDate: end,
            location: nil,
            bodyPreview: nil,
            joinURL: joinURL,
            platform: .teams,
            isAllDay: isAllDay,
            organizer: "Organizer",
            attendees: [],
            accountID: accountID,
            isCancelled: isCancelled
        )
    }
}

