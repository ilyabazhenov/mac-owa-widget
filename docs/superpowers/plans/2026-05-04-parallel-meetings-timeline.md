# Parallel Meetings Timeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the flat meeting list in the popover with a compact timeline that makes overlapping meetings visible while keeping every meeting actionable.

**Architecture:** Add a pure Swift layout helper for overlap clustering and column assignment, then render those layout results from SwiftUI. Keep provider data unchanged and derive all timeline state from existing `CalendarEvent` dates.

**Tech Stack:** Swift 6, SwiftUI, Swift Package Manager, XCTest.

---

### Task 1: Timeline Layout Helper

**Files:**
- Create: `OWAWidget/Views/TimelineMeetingLayout.swift`
- Test: `Tests/OWAWidgetTests/TimelineMeetingLayoutTests.swift`

- [ ] **Step 1: Add failing tests for chained overlap grouping and column assignment**

Create `Tests/OWAWidgetTests/TimelineMeetingLayoutTests.swift` with test events covering same-start meetings, partial overlaps, chained overlaps, one-row column assignment, and non-overlapping clusters.

- [ ] **Step 2: Run tests and confirm the helper is missing**

Run: `swift test --filter TimelineMeetingLayoutTests`

Expected: compilation fails because `TimelineMeetingLayout` does not exist.

- [ ] **Step 3: Implement layout helper**

Create `OWAWidget/Views/TimelineMeetingLayout.swift` with:

- `TimelineMeetingCluster`
- `TimelineMeetingItem`
- `TimelineMeetingLayout.makeClusters(events:calendar:)`
- one-row column assignment
- offset and width fractions clamped to a readable minimum

- [ ] **Step 4: Run helper tests**

Run: `swift test --filter TimelineMeetingLayoutTests`

Expected: tests pass.

### Task 2: Timeline SwiftUI Views

**Files:**
- Modify: `OWAWidget/Views/MeetingListView.swift`
- Create: `OWAWidget/Views/TimelineMeetingBlockView.swift`

- [ ] **Step 1: Render each section as timeline clusters**

Update `MeetingListView` so non-empty sections call `TimelineMeetingLayout.makeClusters(events:)` and render clusters instead of flat rows.

- [ ] **Step 2: Add block view**

Create `TimelineMeetingBlockView` to display title, time range, optional platform icon, current status styling, and join button.

- [ ] **Step 3: Preserve empty state and section headers**

Keep the existing `emptyState` and `sectionHeader` behavior.

### Task 3: Localization and Visual Polish

**Files:**
- Modify: `OWAWidget/Resources/en.lproj/Localizable.strings`
- Modify: `OWAWidget/Resources/ru.lproj/Localizable.strings`
- Modify: `OWAWidget/Views/TimelineMeetingBlockView.swift`

- [ ] **Step 1: Add labels for overlapping clusters**

Add localized strings for overlap cluster metadata such as `meeting.parallel.window`.

- [ ] **Step 2: Use restrained macOS styling**

Use system colors, compact typography, a narrow left status strip, and platform colors only as accents.

### Task 4: Verification

**Files:**
- No source file changes expected.

- [ ] **Step 1: Run unit tests**

Run: `swift test`

Expected: all tests pass.

- [ ] **Step 2: Run build**

Run: `swift build`

Expected: build succeeds.
