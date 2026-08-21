import XCTest
@testable import OWAWidget

/// Provider behaviour against a fake store. Nothing here constructs `EKEventStore`, so the suite
/// can never raise the system calendar prompt.
final class EventKitCalendarProviderTests: XCTestCase {

    private actor FakeStore: EventKitStoring {
        var status: EventKitAccessStatus
        var snapshots: [EventKitEventSnapshot]
        private(set) var requestedIdentifiers: [[String]] = []
        private(set) var requestAccessCallCount = 0

        init(status: EventKitAccessStatus = .fullAccess, snapshots: [EventKitEventSnapshot] = []) {
            self.status = status
            self.snapshots = snapshots
        }

        func authorizationStatus() -> EventKitAccessStatus { status }

        func requestAccess() -> EventKitAccessStatus {
            requestAccessCallCount += 1
            status = .fullAccess
            return status
        }

        func calendars() -> [EventKitCalendarSnapshot] { [] }

        func events(
            from start: Date,
            to end: Date,
            calendarIdentifiers: [String]
        ) -> [EventKitEventSnapshot] {
            requestedIdentifiers.append(calendarIdentifiers)
            return snapshots
        }
    }

    private func snapshot(
        id: String,
        title: String,
        start: TimeInterval,
        calendar: String = "cal-1"
    ) -> EventKitEventSnapshot {
        EventKitEventSnapshot(
            eventIdentifier: id,
            calendarIdentifier: calendar,
            title: title,
            startDate: Date(timeIntervalSinceReferenceDate: start),
            endDate: Date(timeIntervalSinceReferenceDate: start + 1800)
        )
    }

    private func account(calendarIdentifiers: [String]?) -> CalendarAccount {
        CalendarAccount(
            displayName: "Google",
            serverURL: "",
            email: "",
            accountType: .eventKit,
            calendarIdentifiers: calendarIdentifiers
        )
    }

    private let window = (
        start: Date(timeIntervalSinceReferenceDate: 0),
        end: Date(timeIntervalSinceReferenceDate: 100_000)
    )

    func testReadsOnlyTheSelectedCalendars() async throws {
        let store = FakeStore(snapshots: [snapshot(id: "a", title: "A", start: 100)])
        let provider = EventKitCalendarProvider(
            account: account(calendarIdentifiers: ["cal-1", "cal-2"]),
            store: store
        )

        _ = try await provider.fetchEvents(from: window.start, to: window.end)

        let requested = await store.requestedIdentifiers
        XCTAssertEqual(requested, [["cal-1", "cal-2"]])
    }

    /// An account that was never configured reads everything; the store treats an empty list as
    /// "all calendars".
    func testUnconfiguredAccountReadsEveryCalendar() async throws {
        let store = FakeStore(snapshots: [])
        let provider = EventKitCalendarProvider(account: account(calendarIdentifiers: nil), store: store)

        _ = try await provider.fetchEvents(from: window.start, to: window.end)

        let requested = await store.requestedIdentifiers
        XCTAssertEqual(requested, [[]])
    }

    /// "I unchecked everything" must not collapse into "show me everything".
    func testEmptySelectionReturnsNothingWithoutTouchingTheStore() async throws {
        let store = FakeStore(snapshots: [snapshot(id: "a", title: "A", start: 100)])
        let provider = EventKitCalendarProvider(account: account(calendarIdentifiers: []), store: store)

        let events = try await provider.fetchEvents(from: window.start, to: window.end)

        XCTAssertTrue(events.isEmpty)
        let requested = await store.requestedIdentifiers
        XCTAssertTrue(requested.isEmpty)
    }

    func testReturnsEventsSortedByStart() async throws {
        let store = FakeStore(snapshots: [
            snapshot(id: "late", title: "Позже", start: 5_000),
            snapshot(id: "early", title: "Раньше", start: 1_000)
        ])
        let provider = EventKitCalendarProvider(account: account(calendarIdentifiers: ["cal-1"]), store: store)

        let events = try await provider.fetchEvents(from: window.start, to: window.end)

        XCTAssertEqual(events.map(\.title), ["Раньше", "Позже"])
    }

    func testValidateCredentialsAsksForAccessOnlyWhenUndecided() async throws {
        let undecided = FakeStore(status: .notDetermined)
        let provider = EventKitCalendarProvider(account: account(calendarIdentifiers: nil), store: undecided)
        try await provider.validateCredentials()
        var calls = await undecided.requestAccessCallCount
        XCTAssertEqual(calls, 1)

        let granted = FakeStore(status: .fullAccess)
        let second = EventKitCalendarProvider(account: account(calendarIdentifiers: nil), store: granted)
        try await second.validateCredentials()
        calls = await granted.requestAccessCallCount
        XCTAssertEqual(calls, 0)
    }

    func testValidateCredentialsFailsWhenAccessIsDenied() async {
        let store = FakeStore(status: .denied)
        let provider = EventKitCalendarProvider(account: account(calendarIdentifiers: nil), store: store)

        do {
            try await provider.validateCredentials()
            XCTFail("Expected denied access to throw")
        } catch {
            XCTAssertEqual(error as? EventKitStoreError, .accessDenied)
        }
    }

    /// Write-only access reads as a failure rather than an empty calendar: the difference matters
    /// because only one of the two is something the user can fix.
    func testWriteOnlyAccessIsReportedAsAFailure() async {
        let store = FakeStore(status: .writeOnly)
        let provider = EventKitCalendarProvider(account: account(calendarIdentifiers: nil), store: store)

        do {
            try await provider.validateCredentials()
            XCTFail("Expected write-only access to throw")
        } catch {
            XCTAssertEqual(error as? EventKitStoreError, .writeOnlyAccess)
        }
    }

    func testFetchDetailsResolvesTheSameOccurrence() async throws {
        let raw = EventKitEventSnapshot(
            eventIdentifier: "series",
            calendarIdentifier: "cal-1",
            title: "Стендап",
            startDate: Date(timeIntervalSinceReferenceDate: 1_000),
            endDate: Date(timeIntervalSinceReferenceDate: 2_800),
            occurrenceDate: Date(timeIntervalSinceReferenceDate: 1_000),
            hasRecurrenceRules: true,
            notes: "Повестка",
            attendees: [
                EventKitParticipantSnapshot(
                    name: "Коллега",
                    email: "colleague@example.com",
                    isCurrentUser: false,
                    role: .required,
                    status: .accepted
                )
            ]
        )
        let store = FakeStore(snapshots: [raw])
        let provider = EventKitCalendarProvider(account: account(calendarIdentifiers: ["cal-1"]), store: store)
        let fetched = try await provider.fetchEvents(from: window.start, to: window.end)
        let event = try XCTUnwrap(fetched.first)

        let details = try await provider.fetchDetails(for: event)

        XCTAssertEqual(details.attendees.count, 1)
        XCTAssertEqual(details.body, "Повестка")
    }

    // MARK: - Read-only contract

    func testMutatingOperationsStayUnsupported() async {
        let provider = EventKitCalendarProvider(
            account: account(calendarIdentifiers: ["cal-1"]),
            store: FakeStore()
        )
        let event = CalendarEvent(
            id: "x",
            title: "Встреча",
            startDate: Date(),
            endDate: Date().addingTimeInterval(1800),
            location: nil,
            bodyPreview: nil,
            joinURL: nil,
            platform: .generic,
            isAllDay: false,
            organizer: nil,
            accountID: UUID()
        )

        do {
            try await provider.respondToMeeting(event, action: .accept)
            XCTFail("Expected RSVP to be unsupported")
        } catch {
            XCTAssertTrue(error is CalendarProviderError)
        }

        do {
            _ = try await provider.findPeople(query: "кто-нибудь")
            XCTFail("Expected people search to be unsupported")
        } catch {
            XCTAssertTrue(error is CalendarProviderError)
        }
    }

    // MARK: - Access recovery after an update

    /// TCC ties the grant to the code signature, and this app is ad-hoc signed — every update
    /// looks like a different app and the permission reverts to undecided. Asking again from the
    /// sync is what turns that into one dialog instead of an account that quietly stops working.
    func testFetchAsksAgainWhenAnUpdateResetTheGrant() async throws {
        let store = FakeStore(status: .notDetermined, snapshots: [snapshot(id: "a", title: "A", start: 100)])
        let provider = EventKitCalendarProvider(account: account(calendarIdentifiers: ["cal-1"]), store: store)

        let events = try await provider.fetchEvents(from: window.start, to: window.end)

        let calls = await store.requestAccessCallCount
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(events.count, 1)
    }

    /// A denial is an answer. Re-asking on every sync would turn it into nagging.
    func testFetchNeverReopensADecisionTheUserAlreadyMade() async {
        let store = FakeStore(status: .denied, snapshots: [])
        let provider = EventKitCalendarProvider(account: account(calendarIdentifiers: ["cal-1"]), store: store)

        _ = try? await provider.fetchEvents(from: window.start, to: window.end)

        let calls = await store.requestAccessCallCount
        XCTAssertEqual(calls, 0)
    }

    func testGrantedAccessIsNotAskedForAgain() async throws {
        let store = FakeStore(status: .fullAccess, snapshots: [snapshot(id: "a", title: "A", start: 100)])
        let provider = EventKitCalendarProvider(account: account(calendarIdentifiers: ["cal-1"]), store: store)

        _ = try await provider.fetchEvents(from: window.start, to: window.end)

        let calls = await store.requestAccessCallCount
        XCTAssertEqual(calls, 0)
    }
}
