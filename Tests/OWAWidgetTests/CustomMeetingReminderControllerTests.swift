import AppKit
import XCTest
@testable import OWAWidget

@MainActor
final class CustomMeetingReminderControllerTests: XCTestCase {
    private let debugDelayKey = "OWA_TEST_DELAY_SECONDS"
    private let accountID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: debugDelayKey)
        super.tearDown()
    }

    func testCancelAllWithoutClosingKeepsAutoDismissForVisibleBanner() async throws {
        let controller = CustomMeetingReminderController()
        UserDefaults.standard.set(0.05, forKey: debugDelayKey)

        controller.reschedule(
            events: [makeDebugEvent(id: "debug-reminder-visible")],
            leadMinutes: 1,
            localization: .english,
            sound: .none
        )

        try await waitForVisibleBanner(on: controller)
        XCTAssertNotNil(currentDismissWorkItem(on: controller))

        controller.cancelAll(closeActiveReminder: false)

        XCTAssertNotNil(currentDismissWorkItem(on: controller))

        controller.cancelAll(closeActiveReminder: true)
    }

    func testJoinActionClosesVisibleBannerAndClearsDismissWorkItem() async throws {
        let controller = CustomMeetingReminderController()
        UserDefaults.standard.set(0.05, forKey: debugDelayKey)
        var onJoinCalls = 0
        controller.onJoin = { _ in onJoinCalls += 1 }
        let event = makeDebugEvent(id: "debug-reminder-join-close")

        controller.reschedule(
            events: [event],
            leadMinutes: 1,
            localization: .english,
            sound: .none
        )

        try await waitForVisibleBanner(on: controller)
        XCTAssertNotNil(currentPanel(on: controller))
        XCTAssertNotNil(currentDismissWorkItem(on: controller))

        let reminderItem = MeetingReminderItem(
            eventID: event.id,
            title: event.title,
            startDate: event.startDate,
            endDate: event.endDate,
            platform: event.platform,
            joinURL: event.joinURL
        )
        controller.handleJoinAction(item: reminderItem, fallbackPanel: nil)

        XCTAssertEqual(onJoinCalls, 1)
        XCTAssertNil(currentPanel(on: controller))
        XCTAssertNil(currentDismissWorkItem(on: controller))
    }

    // MARK: - Duplicate suppression

    func testSecondRescheduleForSameEventWhilePanelIsVisibleDoesNotCreateDuplicatePanel() async throws {
        // Regression test: reschedule() with the same event while a panel is already showing
        // must not spawn a second panel. cancelAll(closeActiveReminder: false) preserves the
        // visible panel; the new work item should be suppressed by recentlyPresentedAt because
        // the suppressionKey is identical and the 60 s window hasn't expired.
        let controller = CustomMeetingReminderController()
        UserDefaults.standard.set(0.05, forKey: debugDelayKey)
        let event = makeDebugEvent(id: "debug-reminder-dedup-same")

        controller.reschedule(events: [event], leadMinutes: 1, localization: .english, sound: .none)
        try await waitForVisibleBanner(on: controller)
        let firstPanel = try XCTUnwrap(currentPanel(on: controller))

        // Reschedule with the same event while the panel is still open.
        // The new work item fires quickly but must be suppressed.
        UserDefaults.standard.set(0.05, forKey: debugDelayKey)
        controller.reschedule(events: [event], leadMinutes: 1, localization: .english, sound: .none)

        try await Task.sleep(nanoseconds: 300_000_000) // 300 ms — enough for the new work item to fire

        let panelAfterSecondReschedule = try XCTUnwrap(currentPanel(on: controller))
        XCTAssertTrue(
            firstPanel === panelAfterSecondReschedule,
            "Reschedule for the same event while panel is visible must not replace the panel"
        )

        controller.cancelAll(closeActiveReminder: true)
    }

    func testRescheduleAfterJoinURLAddedDoesNotCreateDuplicatePanelForSameEvents() async throws {
        // Regression test for the stable-suppressionKey fix:
        // When a joinURL is added to an event between two syncs the cluster's sort order changes,
        // producing a different clusterID. The old code used clusterID as the suppression key,
        // so the second reschedule would bypass suppression and show a duplicate panel.
        // The fix uses sorted event IDs instead (immune to sort-order changes).
        let controller = CustomMeetingReminderController()
        let now = Date()
        let start = now.addingTimeInterval(5 * 60)

        // First sync: two events without joinURL.
        let eventA = CalendarEvent(
            id: "debug-reminder-stable-a",
            title: "Stable A",
            startDate: start,
            endDate: start.addingTimeInterval(1800),
            location: nil, bodyPreview: nil,
            joinURL: nil, platform: .generic,
            isAllDay: false, organizer: nil,
            accountID: accountID
        )
        let eventB = CalendarEvent(
            id: "debug-reminder-stable-b",
            title: "Stable B",
            startDate: start.addingTimeInterval(60),
            endDate: start.addingTimeInterval(1860),
            location: nil, bodyPreview: nil,
            joinURL: nil, platform: .generic,
            isAllDay: false, organizer: nil,
            accountID: accountID
        )

        UserDefaults.standard.set(0.05, forKey: debugDelayKey)
        controller.reschedule(events: [eventA, eventB], leadMinutes: 1, localization: .english, sound: .none)
        try await waitForVisibleBanner(on: controller)
        let firstPanel = try XCTUnwrap(currentPanel(on: controller))

        // Second sync: event B gains a joinURL → different clusterID, same sorted event IDs.
        let eventBWithURL = CalendarEvent(
            id: "debug-reminder-stable-b",
            title: "Stable B",
            startDate: start.addingTimeInterval(60),
            endDate: start.addingTimeInterval(1860),
            location: nil, bodyPreview: nil,
            joinURL: URL(string: "https://teams.example.com/join"), platform: .teams,
            isAllDay: false, organizer: nil,
            accountID: accountID
        )

        UserDefaults.standard.set(0.05, forKey: debugDelayKey)
        controller.reschedule(events: [eventA, eventBWithURL], leadMinutes: 1, localization: .english, sound: .none)
        try await Task.sleep(nanoseconds: 300_000_000)

        let panelAfterJoinURLAdded = try XCTUnwrap(currentPanel(on: controller))
        XCTAssertTrue(
            firstPanel === panelAfterJoinURLAdded,
            "Adding a joinURL to an event between syncs (changing clusterID) must not create a duplicate panel"
        )

        controller.cancelAll(closeActiveReminder: true)
    }

    private func waitForVisibleBanner(
        on controller: CustomMeetingReminderController,
        timeout: TimeInterval = 2.0
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if currentDismissWorkItem(on: controller) != nil {
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Expected reminder banner to become visible within timeout")
    }

    private func currentDismissWorkItem(on controller: CustomMeetingReminderController) -> DispatchWorkItem? {
        let mirror = Mirror(reflecting: controller)
        return mirror.descendant("dismissWorkItem") as? DispatchWorkItem
    }

    private func currentPanel(on controller: CustomMeetingReminderController) -> NSPanel? {
        let mirror = Mirror(reflecting: controller)
        return mirror.descendant("currentPanel") as? NSPanel
    }

    private func makeDebugEvent(id: String) -> CalendarEvent {
        let now = Date()
        let start = now.addingTimeInterval(5 * 60)
        return CalendarEvent(
            id: id,
            title: "Debug reminder",
            startDate: start,
            endDate: start.addingTimeInterval(30 * 60),
            location: nil,
            bodyPreview: nil,
            joinURL: URL(string: "https://example.com/join"),
            platform: .teams,
            isAllDay: false,
            organizer: nil,
            attendees: [],
            accountID: accountID
        )
    }
}
