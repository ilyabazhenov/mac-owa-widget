# Parallel Meetings Timeline Design

## Goal

Make overlapping meetings visually obvious in the menu bar popover while keeping every meeting as its own independently actionable block.

## Current State

The nearest-meeting banner already groups meetings that start within a five-minute window. The main meeting list is still a flat chronological list, so overlapping meetings such as `10:00-10:30` and `10:15-10:45` look unrelated.

## Desired Behavior

The main day sections should display meetings as a compact horizontal timeline:

- each meeting remains a separate block;
- block horizontal position represents start time;
- block width represents duration;
- overlapping meetings are shown in one horizontal row as adjacent columns;
- chained overlaps belong to the same visual cluster;
- every block can still show title, time, platform state, and join action.

## Scope

Implement the timeline in the popover meeting list. Keep account sync, providers, notifications, and generated Xcode project files unchanged.

## UI Direction

Use the approved mockup in `docs/parallel-meetings-timeline-mockup.svg` as the visual reference. The popover is narrow, so the implementation should prioritize readable blocks over a full calendar grid. Single-meeting clusters should look calmer than dense overlapping clusters.

## Data Model

No provider model change is needed. The layout can be derived from existing `CalendarEvent.startDate` and `CalendarEvent.endDate`.

Create a small layout helper that groups sorted events into overlap clusters. Two events overlap when:

```swift
lhs.startDate < rhs.endDate && rhs.startDate < lhs.endDate
```

Within a cluster, keep all events in one row and assign stable columns by chronological order. Each card still shows its own time range so overlaps remain explicit without adding vertical stack height.

## Components

- `TimelineLayout` helper: pure layout calculation for clusters, columns, offsets, and widths.
- `TimelineMeetingListView`: replaces the flat `MeetingListView` section body.
- `TimelineMeetingBlockView`: renders one event block with title, time, status color, and join button.

## Testing

Add unit tests for overlap grouping and lane assignment. Verify with `swift test` and `swift build`.
