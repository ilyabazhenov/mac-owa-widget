# Global Hotkey Join (⌘⌥J) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user press ⌘⌥J from any app to immediately join the current or next-starting meeting — without touching the menu bar.

**Behaviour by case:**

| # joinable meetings | Action |
|---|---|
| 0 | Show brief auto-dismissing floating panel "No meeting starting now" (2 s) |
| 1 | Immediately open the join URL |
| 2+ | Show selection panel via `MeetingJoinSelectionController.shared` |

A meeting is **joinable** when: `!isAllDay && joinURLForActions != nil && (isHappeningNow \|\| minutesUntilStart <= 2)`.

**Architecture:**
- `GlobalHotkeyService` — singleton, wraps `NSEvent.addGlobalMonitorForEvents`. No entitlement required (app is not sandboxed).
- `GlobalHotkeyFeedbackController` — singleton, shows the "no meeting" NSPanel.
- Pure function `GlobalHotkeyAction.candidates(from:now:)` — extracted so it can be unit-tested without AppKit.
- Wired in `OWAWidgetApp.init()` using the same closure-capture pattern as `notificationDelegate.onJoinFromNotification`.
- Preference toggle in `SettingsViewModel` + `PreferencesView`, UserDefaults key `globalShortcutEnabled`.

**Tech stack:** Swift 6, AppKit, SwiftUI, XCTest.

---

### Task 1: Add `globalShortcut` source to engagement tracking

**Files:**
- Modify: `OWAWidget/Models/MeetingEngagementStats.swift`
- Modify: `OWAWidget/Services/PostJoinDismissController.swift`
- Test: `Tests/OWAWidgetTests/MeetingEngagementStatsTests.swift` (if it exists, otherwise note below)

- [ ] **Step 1: Add `.globalShortcut` to `MeetingJoinSource`**

In `MeetingEngagementStats.swift`, add one case to the existing enum:

```swift
enum MeetingJoinSource: String, Codable, Sendable {
    case meetingRow
    case timelineBlock
    case nextBanner
    case detailPanel
    case reminderNotification
    case reminderPicker
    case inAppReminder
    case globalShortcut   // ← add
}
```

- [ ] **Step 2: Add `.globalShortcut` to `PostJoinContext`**

In `PostJoinDismissController.swift`, add one case:

```swift
@MainActor
enum PostJoinContext {
    case popoverContent
    case detailPanel
    case inAppReminder
    case notificationAction
    case notificationPicker
    case globalShortcut   // ← add
}
```

- [ ] **Step 3: Run build to confirm no regressions**

Run: `swift build`

Expected: build succeeds. The new enum cases need no switch exhaustiveness fixes — all existing switches use `default` or are not exhaustive.

---

### Task 2: Implement `GlobalHotkeyAction` (pure logic, testable)

**Files:**
- Create: `OWAWidget/Services/GlobalHotkeyAction.swift`
- Create: `Tests/OWAWidgetTests/GlobalHotkeyActionTests.swift`

- [ ] **Step 1: Write failing tests**

Create `Tests/OWAWidgetTests/GlobalHotkeyActionTests.swift`:

```swift
import XCTest
@testable import OWAWidget

final class GlobalHotkeyActionTests: XCTestCase {
    // Helpers
    private func makeEvent(
        id: String = UUID().uuidString,
        start: Date,
        end: Date,
        joinURL: URL? = URL(string: "https://teams.example.com/join"),
        isAllDay: Bool = false,
        isCancelled: Bool = false
    ) -> CalendarEvent { ... }

    // Test: empty events → empty candidates
    func testNoCandidatesWhenNoEvents()

    // Test: event happening now with join URL → candidate
    func testEventHappeningNowIsCandidate()

    // Test: event starting in 2 minutes with join URL → candidate
    func testEventStartingIn2MinutesIsCandidate()

    // Test: event starting in 3 minutes → NOT a candidate
    func testEventStartingIn3MinutesIsNotCandidate()

    // Test: cancelled event → NOT a candidate even if happening now
    func testCancelledEventIsNotCandidate()

    // Test: all-day event → NOT a candidate
    func testAllDayEventIsNotCandidate()

    // Test: happening-now event without join URL → NOT a candidate
    func testEventWithoutJoinURLIsNotCandidate()

    // Test: two simultaneous events → two candidates
    func testTwoSimultaneousEventsAreBothCandidates()

    // Test: past event → NOT a candidate
    func testPastEventIsNotCandidate()
}
```

Run: `swift test --filter GlobalHotkeyActionTests`
Expected: compilation fails because `GlobalHotkeyAction` does not exist.

- [ ] **Step 2: Implement `GlobalHotkeyAction`**

Create `OWAWidget/Services/GlobalHotkeyAction.swift`:

```swift
import Foundation

enum GlobalHotkeyAction {
    /// Returns the meetings that qualify for an immediate join via the global shortcut.
    /// Extracted as a pure function so it can be unit-tested without AppKit.
    static func candidates(from events: [CalendarEvent], now: Date) -> [CalendarEvent] {
        events.filter {
            !$0.isAllDay &&
            $0.joinURLForActions != nil &&
            ($0.isHappeningNow(at: now) || $0.minutesUntilStart(from: now) <= 2)
        }
    }
}
```

> Note: `isHappeningNow` and `minutesUntilStart` currently use `Date()` internally. If they do not accept a `now` parameter, add overloads or refactor to accept `now: Date` so they can be tested deterministically. The existing computed properties remain unchanged; add the parameterised versions alongside them:
>
> ```swift
> // CalendarEvent.swift — add next to existing computed properties
> func isHappeningNow(at now: Date) -> Bool {
>     startDate <= now && endDate > now
> }
> func minutesUntilStart(from now: Date) -> Int {
>     max(0, Int(startDate.timeIntervalSince(now) / 60))
> }
> ```

- [ ] **Step 3: Run tests**

Run: `swift test --filter GlobalHotkeyActionTests`
Expected: all tests pass.

---

### Task 3: Implement `GlobalHotkeyService` and `GlobalHotkeyFeedbackController`

**Files:**
- Create: `OWAWidget/Services/GlobalHotkeyService.swift`

- [ ] **Step 1: Implement `GlobalHotkeyService`**

Create `OWAWidget/Services/GlobalHotkeyService.swift`:

```swift
import AppKit

/// Registers a process-wide hotkey (⌘⌥J) that fires even when the app is not frontmost.
/// Requires no special entitlements — the app is not sandboxed.
@MainActor
final class GlobalHotkeyService {
    static let shared = GlobalHotkeyService()

    private var monitor: Any?
    private var lastFiredAt: Date = .distantPast
    private let cooldown: TimeInterval = 2.0

    var onActivate: (() -> Void)?

    private init() {}

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // ⌘⌥J: keyCode 38, exactly Command + Option (no other modifiers)
            guard event.modifierFlags.intersection([.command, .option, .shift, .control]) == [.command, .option],
                  event.keyCode == 38
            else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                let now = Date()
                guard now.timeIntervalSince(self.lastFiredAt) > self.cooldown else { return }
                self.lastFiredAt = now
                self.onActivate?()
            }
        }
    }

    func stop() {
        guard let m = monitor else { return }
        NSEvent.removeMonitor(m)
        monitor = nil
    }
}
```

- [ ] **Step 2: Implement `GlobalHotkeyFeedbackController`**

Add to `OWAWidget/Services/GlobalHotkeyService.swift` (same file — it's small and tightly coupled):

```swift
import SwiftUI

/// Shows a brief auto-dismissing floating panel when ⌘⌥J finds no joinable meeting.
@MainActor
enum GlobalHotkeyFeedbackController {
    private static var activePanel: NSPanel?

    static func showNoMeeting() {
        activePanel?.close()

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 52),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        panel.contentView = NSHostingView(rootView: NoMeetingFeedbackView())

        if let screen = NotificationScreenPolicy.current.resolve() {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(
                x: visible.maxX - panel.frame.width - 18,
                y: visible.maxY - panel.frame.height - 18
            ))
        }

        panel.orderFront(nil)
        activePanel = panel

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            panel.close()
            if activePanel === panel { activePanel = nil }
        }
    }
}

private struct NoMeetingFeedbackView: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "calendar.badge.clock")
                .foregroundStyle(.secondary)
            Text("hotkey.noMeeting", bundle: .main)
                .font(.system(size: 13))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
```

- [ ] **Step 3: Run build**

Run: `swift build`
Expected: build succeeds.

---

### Task 4: Localization strings

**Files:**
- Modify: `OWAWidget/Resources/en.lproj/Localizable.strings`
- Modify: `OWAWidget/Resources/ru.lproj/Localizable.strings`

- [ ] **Step 1: Add EN strings**

Append to `en.lproj/Localizable.strings`:

```
"hotkey.noMeeting" = "No meeting starting now";
"preferences.hotkey.section" = "Keyboard Shortcut";
"preferences.hotkey.toggle" = "Join meeting shortcut (⌘⌥J)";
"preferences.hotkey.hint" = "Press ⌘⌥J from any app to instantly join the current or next-starting meeting.";
```

- [ ] **Step 2: Add RU strings**

Append to `ru.lproj/Localizable.strings`:

```
"hotkey.noMeeting" = "Нет встречи, которую можно присоединить";
"preferences.hotkey.section" = "Быстрая клавиша";
"preferences.hotkey.toggle" = "Присоединиться к встрече (⌘⌥J)";
"preferences.hotkey.hint" = "Нажмите ⌘⌥J из любого приложения, чтобы мгновенно войти в текущую или ближайшую встречу.";
```

---

### Task 5: Preference toggle

**Files:**
- Modify: `OWAWidget/Views/SettingsViewModel.swift`
- Modify: `OWAWidget/Views/PreferencesView.swift`
- Test: `Tests/OWAWidgetTests/SettingsViewModelTests.swift`

- [ ] **Step 1: Add `globalShortcutEnabled` to `SettingsViewModel`**

UserDefaults key: `"globalShortcutEnabled"`, default: `true`.

```swift
// Add to @Published properties
@Published var globalShortcutEnabled: Bool { didSet { updateUnsavedChanges() } }

// In init(), alongside the other properties
self.globalShortcutEnabled = UserDefaults.standard.object(forKey: "globalShortcutEnabled") as? Bool ?? true

// In baselinePreferences init, add:
globalShortcutEnabled: (UserDefaults.standard.object(forKey: "globalShortcutEnabled") as? Bool ?? true)
```

- [ ] **Step 2: Update `PreferencesSnapshot`**

Add to the private `PreferencesSnapshot` struct and all its uses:

```swift
private struct PreferencesSnapshot: Equatable {
    // ... existing fields ...
    let globalShortcutEnabled: Bool   // ← add
}

private func currentPreferencesSnapshot() -> PreferencesSnapshot {
    PreferencesSnapshot(
        // ... existing fields ...
        globalShortcutEnabled: globalShortcutEnabled   // ← add
    )
}
```

Update the `baselinePreferences` initialisation in `init()` the same way.

- [ ] **Step 3: Persist and apply in `savePreferences()`**

```swift
func savePreferences() {
    // ... existing lines ...
    UserDefaults.standard.set(globalShortcutEnabled, forKey: "globalShortcutEnabled")
    if globalShortcutEnabled {
        GlobalHotkeyService.shared.start()
    } else {
        GlobalHotkeyService.shared.stop()
    }
    // ... rest of existing code ...
}
```

- [ ] **Step 4: Add toggle to `PreferencesView`**

Add a new `Section` after the existing "Menu Bar" section (look for `"preferences.menubar.section"` in PreferencesView):

```swift
Section(localization.tr("preferences.hotkey.section")) {
    Toggle(localization.tr("preferences.hotkey.toggle"), isOn: $vm.globalShortcutEnabled)
    Text(localization.tr("preferences.hotkey.hint"))
        .font(.caption)
        .foregroundStyle(.secondary)
}
```

- [ ] **Step 5: Update `SettingsViewModelTests`**

In the existing test file, verify that `globalShortcutEnabled` defaults to `true` and that `hasUnsavedChanges` becomes `true` when it changes. Follow the pattern of existing snapshot equality tests.

Run: `swift test --filter SettingsViewModelTests`
Expected: tests pass.

---

### Task 6: Wire up in `OWAWidgetApp`

**Files:**
- Modify: `OWAWidget/OWAWidgetApp.swift`

- [ ] **Step 1: Add hotkey setup to `init()`**

After the existing `notificationDelegate.onJoinFromNotification` assignment and before `configureAppIcon()`:

```swift
// Global hotkey ⌘⌥J
let hotkeyEnabled = UserDefaults.standard.object(forKey: "globalShortcutEnabled") as? Bool ?? true
GlobalHotkeyService.shared.onActivate = { [calendarService] in
    let now = Date()
    let candidates = GlobalHotkeyAction.candidates(from: calendarService.events, now: now)
    switch candidates.count {
    case 0:
        GlobalHotkeyFeedbackController.showNoMeeting()
    case 1:
        calendarService.openJoinURL(for: candidates[0], source: .globalShortcut)
        PostJoinDismissController.shared.dismissAfterJoin(context: .globalShortcut)
    default:
        let items = candidates.map { MeetingReminderItem(event: $0) }
        MeetingJoinSelectionController.shared.present(items: items) { item in
            calendarService.openJoinURL(for: item, source: .globalShortcut)
        }
    }
}
if hotkeyEnabled {
    GlobalHotkeyService.shared.start()
}
```

> The `[calendarService]` capture pattern is identical to the existing `notificationDelegate.onJoinFromNotification` closure — it captures the `CalendarService` object reference directly from the `@StateObject`'s `wrappedValue`.

- [ ] **Step 2: Run build**

Run: `swift build`
Expected: build succeeds with no warnings.

---

### Task 7: Verification

- [ ] **Step 1: Run all tests**

Run: `swift test`
Expected: all tests pass.

- [ ] **Step 2: Build release**

Run: `make build`
Expected: build succeeds.

- [ ] **Step 3: Manual test — single meeting**

- Set up one upcoming meeting starting within 2 minutes.
- Switch to another app (e.g. Finder).
- Press ⌘⌥J.
- Expected: meeting join URL opens immediately in the browser/app.

- [ ] **Step 4: Manual test — two concurrent meetings**

- Set up two meetings with the same start time.
- Press ⌘⌥J from another app.
- Expected: `MeetingJoinSelectionController` panel appears top-right with both meetings listed.

- [ ] **Step 5: Manual test — no meeting**

- Ensure no meeting starts within 2 minutes.
- Press ⌘⌥J from another app.
- Expected: "No meeting starting now" floating panel appears and auto-dismisses after 2 seconds.

- [ ] **Step 6: Manual test — preference toggle**

- Open Settings → disable the "Join meeting shortcut" toggle → Save.
- Press ⌘⌥J.
- Expected: nothing happens.
- Re-enable toggle → Save → hotkey works again.

- [ ] **Step 7: Manual test — cooldown**

- Press ⌘⌥J twice within 2 seconds.
- Expected: only the first press triggers a join / panel. Second press is ignored.
