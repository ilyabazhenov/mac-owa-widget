# Meeting Detail Panel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the full-screen meeting detail navigation with a bottom inspector panel over the existing day timeline.

**Architecture:** `PopoverView` remains the owner of `selectedEvent` and renders a conditional overlay instead of a `navigationDestination`. A new `MeetingDetailPanelView` owns the panel shell and detail content. `MeetingListView` and `TimelineMeetingBlockView` receive a selected event id so the selected block can be highlighted without changing frame math.

**Tech Stack:** Swift 6, SwiftUI, AppKit clipboard and URL opening, XCTest, Swift Package Manager.

---

### Task 1: Preserve Timeline Structure While Details Are Open

**Files:**
- Modify: `OWAWidget/Views/PopoverView.swift`
- Modify: `OWAWidget/Views/MeetingListView.swift`
- Modify: `OWAWidget/Views/TimelineMeetingBlockView.swift`

- [x] **Step 1: Add selected event plumbing to timeline views**

Add `selectedEventID` to `MeetingListView` and `isSelected` to `TimelineMeetingBlockView`. The selected state changes color emphasis only; it must not alter card width, height, position, or padding.

- [x] **Step 2: Replace meeting navigation with an overlay**

Remove `NavigationStack` and `.navigationDestination` from the normal meeting content path in `PopoverView`. Render the same day content in a `ZStack` and show the panel when `selectedEvent != nil`.

- [x] **Step 3: Keep day navigation behavior**

Keep the existing behavior where previous/next day buttons clear `selectedEvent`.

### Task 2: Build Meeting Detail Panel

**Files:**
- Create: `OWAWidget/Views/MeetingDetailPanelView.swift`
- Modify: `OWAWidget/Views/MeetingDetailView.swift`

- [x] **Step 1: Extract reusable detail content**

Move detail rows, actions, and optional body preview into reusable SwiftUI views in the new panel file.

- [x] **Step 2: Add bottom panel shell**

Create `MeetingDetailPanelView(event:onClose:)` with a compact header, close button, visible join/copy actions, metadata rows, rounded top corners, and bottom transition support.

- [x] **Step 3: Keep full detail wrapper compiling**

Update `MeetingDetailView` to use the reusable content or keep it as a compatible wrapper if another call site remains.

### Task 3: Verify

**Files:**
- Modify: focused XCTest files only if compile-time coverage needs updating.

- [x] **Step 1: Build**

Run `swift build`.

- [x] **Step 2: Focused tests**

Run timeline and popover layout tests if build succeeds:

```bash
swift test --filter TimelineMeetingBlockViewTests
swift test --filter PopoverViewLayoutTests
```

- [x] **Step 3: Review diff**

Confirm no generated project files, build artifacts, provider code, sync code, or notification code changed.
