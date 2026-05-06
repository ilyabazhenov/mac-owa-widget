# Update Availability Indicator Implementation Plan

> **For agentic workers:** Use superpowers:subagent-driven-development or executing-plans to implement task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Passive GitHub release check (6h), popover banner with open/skip, Preferences toggle + Check now, version compare unit tests.

**Architecture:** `UpdateCheckService` (@MainActor `ObservableObject`) uses `URLSession` + `UserDefaults` cache; `UpdateAvailableBannerView` in `PopoverView` stack; `UpdateVersionComparison` for semver-ish compare; RU/EN strings in `Localizable.strings`.

**Tech stack:** Swift 6, SwiftUI, macOS 13+, GitHub REST JSON.

---

### Task 1: Design + plan artifacts

**Files:**

- Create: [docs/superpowers/specs/2026-05-06-update-availability-indicator-design.md](../specs/2026-05-06-update-availability-indicator-design.md)
- Create: [docs/superpowers/plans/2026-05-06-update-availability-indicator.md](./2026-05-06-update-availability-indicator.md)

- [x] Write spec and implementation plan
- [x] Commit docs

### Task 2: Version comparison + service

**Files:**

- Create: `OWAWidget/Services/UpdateCheckService.swift`

- [ ] Add `AvailableUpdate`, `GitHubLatestRelease` (private Decodable), `UpdateVersionComparison`
- [ ] Implement `UpdateCheckService` with `start`, `checkNow`, `skip`, throttle, timer, cache read/write
- [ ] Log errors with `Logger` (`subsystem: com.owawidget`, `category: UpdateCheckService`)

### Task 3: Unit tests

**Files:**

- Create: `Tests/OWAWidgetTests/UpdateCheckServiceTests.swift`

- [ ] Cover `compare` cases from spec (1.0.9 vs 1.0.10, equality, v-prefix, padding, prerelease suffix, 1.1 vs 1.0.99)

### Task 4: UI + wiring

**Files:**

- Create: `OWAWidget/Views/UpdateAvailableBannerView.swift`
- Modify: `OWAWidget/Views/PopoverView.swift` — banner in `dayTimelineContent` VStack
- Modify: `OWAWidget/OWAWidgetApp.swift` — `@StateObject` service, `environmentObject`, `start()`
- Modify: `OWAWidget/Views/PreferencesView.swift` — Updates section
- Modify: `OWAWidget/Views/SettingsView.swift` — pass `environmentObject(updateCheck)` if needed (prefer App-level `.environmentObject` on `SettingsView`)

### Task 5: Localization

**Files:**

- Modify: `OWAWidget/Resources/en.lproj/Localizable.strings`
- Modify: `OWAWidget/Resources/ru.lproj/Localizable.strings`

### Task 6: Verify

- [ ] `swift build`
- [ ] `swift test`
- [ ] `make run` smoke (optional local VERSION tweak)
