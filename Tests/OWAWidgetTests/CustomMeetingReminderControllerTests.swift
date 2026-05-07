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
