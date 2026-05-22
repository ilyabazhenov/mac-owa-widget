import XCTest
@testable import OWAWidget

/// Covers `AppDelegate.shouldRaiseWindow` — the predicate that decides whether a window
/// should be raised on `applicationDidBecomeActive`. The predicate replaced a permissive
/// inline filter that, in v1.0.37, raised the half-constructed Settings window on
/// macOS Sequoia and crashed the app.
final class AppDelegateWindowRaiseTests: XCTestCase {
    // MARK: - Gate 1: createMeetingVisible flag

    func testReturnsFalseWhenCreateMeetingWindowIsNotVisible() {
        // Even a perfectly-matching create-meeting window must not be raised if the
        // flag says the window is off screen. This is the main guarantee that makes
        // opening Settings safe: applicationDidBecomeActive becomes a no-op when only
        // Settings is open (the app stays in .accessory mode then anyway, but we
        // belt-and-suspenders the predicate).
        let result = AppDelegate.shouldRaiseWindow(
            createMeetingVisible: false,
            identifier: "create-meeting",
            canBecomeMain: true,
            isPanel: false,
            isVisible: true
        )
        XCTAssertFalse(result)
    }

    // MARK: - Gate 2: window must be a regular visible main window

    func testReturnsFalseForPanelEvenWithMatchingIdentifier() {
        // NSPanel-derived windows (sheets, popovers, attached pickers) should never be
        // force-raised; their lifecycle is owned by their parent.
        let result = AppDelegate.shouldRaiseWindow(
            createMeetingVisible: true,
            identifier: "create-meeting",
            canBecomeMain: true,
            isPanel: true,
            isVisible: true
        )
        XCTAssertFalse(result)
    }

    func testReturnsFalseWhenWindowCannotBecomeMain() {
        // Status item windows, accessory windows etc. report canBecomeMain == false.
        // Calling makeKeyAndOrderFront on them at the wrong moment is what triggers
        // AppKit asserts on Sequoia.
        let result = AppDelegate.shouldRaiseWindow(
            createMeetingVisible: true,
            identifier: "create-meeting",
            canBecomeMain: false,
            isPanel: false,
            isVisible: true
        )
        XCTAssertFalse(result)
    }

    func testReturnsFalseWhenWindowIsNotVisible() {
        // Off-screen / closed window. Forcing visibility from the activation handler
        // would resurrect a window the user just dismissed.
        let result = AppDelegate.shouldRaiseWindow(
            createMeetingVisible: true,
            identifier: "create-meeting",
            canBecomeMain: true,
            isPanel: false,
            isVisible: false
        )
        XCTAssertFalse(result)
    }

    // MARK: - Gate 3: identifier must match create-meeting

    func testReturnsFalseForNilIdentifier() {
        // Windows without an identifier (legacy AppKit windows, system pop-ups) must
        // never be raised — the predicate is intentionally strict.
        let result = AppDelegate.shouldRaiseWindow(
            createMeetingVisible: true,
            identifier: nil,
            canBecomeMain: true,
            isPanel: false,
            isVisible: true
        )
        XCTAssertFalse(result)
    }

    func testReturnsFalseForSettingsWindow() {
        // The core regression we are guarding against: settings window must NOT be
        // raised by this code path. The crash in v1.0.37 happened exactly because the
        // old filter accepted any canBecomeMain visible window, including settings.
        let result = AppDelegate.shouldRaiseWindow(
            createMeetingVisible: true,
            identifier: "settings",
            canBecomeMain: true,
            isPanel: false,
            isVisible: true
        )
        XCTAssertFalse(result)
    }

    func testReturnsFalseForUnrelatedIdentifier() {
        let result = AppDelegate.shouldRaiseWindow(
            createMeetingVisible: true,
            identifier: "popover-host",
            canBecomeMain: true,
            isPanel: false,
            isVisible: true
        )
        XCTAssertFalse(result)
    }

    // MARK: - Happy path

    func testReturnsTrueForExactCreateMeetingIdentifier() {
        let result = AppDelegate.shouldRaiseWindow(
            createMeetingVisible: true,
            identifier: "create-meeting",
            canBecomeMain: true,
            isPanel: false,
            isVisible: true
        )
        XCTAssertTrue(result)
    }

    func testReturnsTrueForSwiftUIDecoratedIdentifier() {
        // SwiftUI can decorate the raw identifier with suffixes like
        // "create-meeting-AppWindow-1". The exact format isn't a stable contract
        // across macOS versions, so the predicate uses `.contains`. This test pins
        // that behaviour so a future "tighten to equality" refactor breaks loudly.
        let result = AppDelegate.shouldRaiseWindow(
            createMeetingVisible: true,
            identifier: "create-meeting-AppWindow-1",
            canBecomeMain: true,
            isPanel: false,
            isVisible: true
        )
        XCTAssertTrue(result)
    }

    func testReturnsTrueForIdentifierWithSwiftUIPrefix() {
        // Guard against SwiftUI prepending an internal namespace to the user-supplied
        // Window(id:) value. `.contains` covers both prefix and suffix decorations.
        let result = AppDelegate.shouldRaiseWindow(
            createMeetingVisible: true,
            identifier: "SwiftUI.AppWindow.create-meeting",
            canBecomeMain: true,
            isPanel: false,
            isVisible: true
        )
        XCTAssertTrue(result)
    }

    // MARK: - Gate ordering / short-circuit

    func testFlagGateShortCircuitsAllOtherChecks() {
        // When the create-meeting window is not on screen the predicate must return
        // false regardless of any other input. Documents the precedence of gate 1.
        let result = AppDelegate.shouldRaiseWindow(
            createMeetingVisible: false,
            identifier: "create-meeting",
            canBecomeMain: false,
            isPanel: true,
            isVisible: false
        )
        XCTAssertFalse(result)
    }
}
