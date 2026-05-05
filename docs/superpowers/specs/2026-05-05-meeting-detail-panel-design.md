# Meeting Detail Panel Design

## Goal

Make opening a meeting feel like a continuation of the day timeline instead of a hard navigation to a different page structure.

## Current State

`PopoverView` uses `NavigationStack` and `navigationDestination` for `selectedEvent`. Selecting a meeting replaces the whole timeline page with `MeetingDetailView`. The destination has a different header, removes the app controls, hides the date navigation and footer context, and leaves a mostly empty detail page for short meetings.

This creates a visually abrupt transition inside a small menu bar popover.

## Desired Behavior

Selecting a meeting should open an inspector-style detail panel over the current day view:

- the app header, date navigation, nearest-meeting banner, timeline, and footer remain structurally present;
- the selected timeline block remains visually connected to the opened details;
- the detail panel appears with a soft move-and-fade transition;
- closing the panel restores the same timeline scroll position;
- selecting another meeting while the panel is open swaps the panel content without pushing a new screen;
- changing the selected day closes the panel.

## UI Direction

Use a bottom overlay panel inside the popover content area. The panel should feel like an inspector, not a full page:

- height around 40-55% of the content area, with a sensible minimum for actions;
- rounded top corners and a subtle shadow or separator;
- a compact header with close/back affordance, title, and time;
- immediately visible primary actions: join and copy link;
- metadata rows for date/time, location or meeting URL, organizer, and attendees;
- optional body preview in a scrollable lower area.

The day view behind the panel should be slightly dimmed or softened, but remain recognizable as the same timeline page. The timeline does not need to stay interactive while the panel is open.

## Architecture

Keep `selectedEvent` in `PopoverView`, but stop using `navigationDestination` for meeting details. Render the day view normally and attach a conditional overlay when `selectedEvent != nil`.

Introduce a dedicated panel shell named `MeetingDetailPanelView`, and extract shared detail content from `MeetingDetailView` where practical. The reusable content owns the display of metadata, join, copy, and body preview. The panel shell owns the close control, height, background, and transition.

Keep `MeetingDetailView` only if it remains useful as a thin wrapper around the shared detail content. Otherwise remove the obsolete full-page meeting detail path.

## Interaction Details

Opening:

- tapping a timeline block or nearest-meeting banner sets `selectedEvent`;
- the panel appears from the bottom with opacity;
- the currently selected event receives a visible selected state that does not change timeline frame math.

Closing:

- tapping the panel close button clears `selectedEvent`;
- pressing Escape is out of scope for the first pass unless the existing SwiftUI/AppKit setup already exposes it without extra infrastructure;
- date navigation clears `selectedEvent`, matching current behavior.

Actions:

- join opens `event.joinURL` through `NSWorkspace.shared.open`;
- copy writes the URL to `NSPasteboard` and shows the existing copied state;
- events without a join URL still show available metadata and omit unavailable actions.

## Scope

In scope:

- replacing meeting detail navigation with an overlay panel;
- preserving the timeline day view while details are open;
- reusing or lightly restructuring existing detail UI code;
- focused visual polish for the transition and panel.

Out of scope:

- redesigning the full timeline layout;
- changing calendar providers, sync, caching, notifications, or settings;
- adding new meeting fields not already present in `CalendarEvent`;
- changing generated Xcode project files.

## Testing

Run `swift build`.

Manual checks:

- open details from a timeline event;
- open details from the nearest-meeting banner;
- close the panel and confirm timeline scroll position is preserved;
- switch days and confirm the panel closes;
- select a different meeting while the panel is open;
- verify join and copy actions still work.
