import XCTest
@testable import OWAWidget

/// A cancelled meeting cannot be answered: Exchange refuses it with
/// `ErrorCalendarIsCancelledForAccept`. The card hides the buttons, and the service stops any
/// other path (an old invitation email, the invitation panel) before it reaches Exchange.
@MainActor
final class CancelledMeetingResponseTests: XCTestCase {

    private actor RecordingProvider: CalendarProvider {
        nonisolated let account: CalendarAccount
        private(set) var responses: [MeetingResponseAction] = []

        init(account: CalendarAccount) {
            self.account = account
        }

        func fetchEvents(from start: Date, to end: Date) async throws -> [CalendarEvent] { [] }
        func validateCredentials() async throws {}

        func respondToMeeting(_ event: CalendarEvent, action: MeetingResponseAction) async throws {
            responses.append(action)
        }
    }

    private final class NullEventCacheStore: EventCacheStoring {
        func load() -> EventCacheSnapshot? { nil }
        func save(events: [CalendarEvent], rangeStart: Date, rangeEnd: Date) {}
        func clear() {}
    }

    private let account = CalendarAccount(displayName: "Exchange", serverURL: "", email: "", accountType: .owa)

    private func event(
        title: String = "Planning",
        isCancelled: Bool = false,
        isOrganizer: Bool = false,
        responseType: MeetingResponseType = .notResponded,
        changeKey: String? = "ck"
    ) -> CalendarEvent {
        let start = Date().addingTimeInterval(3600)
        return CalendarEvent(
            id: "e1",
            title: title,
            startDate: start,
            endDate: start.addingTimeInterval(1800),
            location: nil,
            bodyPreview: nil,
            joinURL: nil,
            platform: .generic,
            isAllDay: false,
            organizer: "Organizer",
            accountID: account.id,
            isCancelled: isCancelled,
            isOrganizer: isOrganizer,
            responseType: responseType,
            changeKey: changeKey
        )
    }

    private func makeService(provider: RecordingProvider) -> CalendarService {
        CalendarService(
            providers: [provider],
            eventCacheStore: NullEventCacheStore(),
            notificationService: SilentNotificationService(),
            customMeetingReminders: SilentMeetingReminderController(),
            loadPersistedAccounts: false,
            startBackgroundTasks: false
        )
    }

    // MARK: - acceptsResponse

    func testInvitationAcceptsResponse() {
        XCTAssertTrue(event().acceptsResponse)
        XCTAssertTrue(event(responseType: .accepted).acceptsResponse)
    }

    func testCancelledMeetingDoesNotAcceptResponse() {
        XCTAssertFalse(event(isCancelled: true).acceptsResponse)
    }

    /// Cached payloads may carry the cancellation only in the subject.
    func testMeetingCancelledBySubjectDoesNotAcceptResponse() {
        XCTAssertFalse(event(title: "Отменено: Planning").acceptsResponse)
        XCTAssertFalse(event(title: "Canceled: Planning").acceptsResponse)
    }

    func testOwnMeetingOrReadOnlyCalendarDoesNotAcceptResponse() {
        XCTAssertFalse(event(isOrganizer: true).acceptsResponse)
        XCTAssertFalse(event(responseType: .organizer).acceptsResponse)
        XCTAssertFalse(event(changeKey: nil).acceptsResponse)
    }

    // MARK: - CalendarService

    func testRespondingToCancelledMeetingNeverReachesProvider() async {
        let provider = RecordingProvider(account: account)
        let service = makeService(provider: provider)
        let cancelled = event(isCancelled: true)
        service.replaceEventsForTests([cancelled])

        do {
            try await service.respondToMeeting(cancelled, action: .accept)
            XCTFail("Expected meetingCancelled")
        } catch CalendarProviderError.meetingCancelled {
        } catch {
            XCTFail("Unexpected error \(error)")
        }

        let sent = await provider.responses
        XCTAssertEqual(sent, [])
        // No optimistic "accepted" left behind on the timeline.
        XCTAssertEqual(service.events.first?.responseType, .notResponded)
    }

    func testRespondingToActiveMeetingStillReachesProvider() async throws {
        let provider = RecordingProvider(account: account)
        let service = makeService(provider: provider)
        let invitation = event()
        service.replaceEventsForTests([invitation])

        try await service.respondToMeeting(invitation, action: .tentative)

        let sent = await provider.responses
        XCTAssertEqual(sent, [.tentative])
    }

    // MARK: - Mail

    /// An old invitation email asks the calendar whether its meeting was cancelled since.
    func testMailBackendReportsCancelledMeeting() {
        let service = makeService(provider: RecordingProvider(account: account))
        service.replaceEventsForTests([event(isCancelled: true)])
        XCTAssertTrue(service.mailMeetingIsCancelled(calendarItemID: "e1"))
        XCTAssertFalse(service.mailMeetingIsCancelled(calendarItemID: "unknown"))

        service.replaceEventsForTests([event()])
        XCTAssertFalse(service.mailMeetingIsCancelled(calendarItemID: "e1"))
    }
}
