# Menu Bar Display Modes Design

**Date:** 2026-05-07  
**Status:** Approved for implementation

## Goal

Give users two explicit menu bar display modes:

- **Countdown (current)** — the existing behavior, kept as the default.
- **Status** — a compact current-day state indicator for dense calendars.

Both modes must avoid meeting titles in the macOS menu bar. Full meeting titles remain in the popover and, where useful, in help/tooltip text.

## Product Rationale

Modern Mac menu bars have limited space, especially on notebooks with a notch and many system/app icons. Meeting titles are usually too long for this area, so the menu bar label should answer a compact operational question instead:

- in **Countdown** mode: when is the nearest future meeting;
- in **Status** mode: what is the user's current calendar state today.

This keeps the existing experience stable while adding a more frequent-use mode for people with dense calendars.

## Mode Selection

Add a user preference named **Menu bar display** with two options:

| Mode | Description | Default |
|------|-------------|---------|
| `Countdown` | Current behavior: icon plus countdown/time for the nearest future meeting. | Yes |
| `Status` | Compact state labels: `Next 7m`, `Now 18m`, `Now x2`, `Free 1h`, `Free`. | No |

Persist the selected mode in `UserDefaults`. Existing users should remain on `Countdown` after updating.

## Countdown (Current)

This mode preserves the current menu bar behavior exactly:

- Shows the system calendar icon.
- If any non-ended meeting is happening now, the icon becomes `calendar.badge.clock` and the whole label pulses.
- The text is based only on the nearest future event where `startDate > now`.
- If the nearest future event is today:
  - under one hour away: show minutes rounded up, for example ` 7m` or `35m`;
  - one hour or more away: show hours rounded up, for example ` 1h` or ` 4h`.
- If today has no more future events but the nearest future event is tomorrow, show its short start time, for example `09:30`.
- If there is no future event, show only the icon.
- Meeting titles are not shown in the menu bar.

## Status

This mode is a current-day status indicator. Labels are always English for compactness and recognizability, regardless of the selected app language.

Display rules:

- Time values in labels are rounded up to the nearest whole minute.
- For `Free` labels, use `Xm` for values under 60 minutes and `Xh` for 60 minutes or more, with hours rounded up from remaining minutes.

- If one non-all-day meeting is active now, show `Now 18m`, where the time is rounded up until that meeting ends.
- If multiple non-all-day meetings are active now, show `Now x2` (replace `2` with the active-meeting count).
- If no meeting is active and the next non-all-day meeting starts today in 15 minutes or less (`<= 15m`), show `Next 7m`.
- If no meeting is active and the next non-all-day meeting starts today more than 15 minutes from now (`> 15m`), show `Free 1h` or `Free 35m`, rounded up until that meeting starts.
- If today has no more future non-all-day meetings, show `Free`.
- Tomorrow's meetings do not affect the Status label. They remain visible in the popover.
- All-day events do not occupy `Now`, `Next`, or `Free` status calculations.

The icon and pulse behavior should remain consistent with the current implementation: when a meeting is active now, use the active meeting icon and pulse; otherwise use the regular calendar icon.

## UI

Add the picker in Preferences near other user-facing behavior settings.

Suggested labels:

- Section/control label:
  - EN: `Menu bar display`
  - RU: `Отображение в строке меню`
- Options:
  - EN: `Countdown (current)` / `Status: Next / Now / Free`
  - RU: `Как сейчас: countdown` / `Status: Next / Now / Free`

The Status option intentionally keeps the sample labels in English.

## Implementation Notes

- Introduce a small menu bar display mode model, for example `MenuBarDisplayMode`.
- Keep countdown formatting behavior covered by the existing `MenuBarCountdownFormatter`.
- Add a dedicated helper/formatter for Status mode so current countdown behavior stays isolated.
- Wire the selected mode through `CalendarService`, `SettingsViewModel`, and `PreferencesView`, following existing preference patterns.
- Avoid changing calendar provider, sync, notification, release, or packaging behavior.

## Testing

Add focused unit tests for:

- default mode is `Countdown`;
- selected mode persists and restores from `UserDefaults`;
- existing countdown behavior remains unchanged, including tomorrow's short-time label;
- Status shows `Now Xm` for one active meeting;
- Status shows `Now xN` for multiple active meetings;
- Status shows `Next Xm` when the next meeting starts within 15 minutes today;
- Status shows `Free Xm` / `Free Xh` when the next meeting today starts later than 15 minutes away;
- Status shows `Free` when today has no more future meetings, even if tomorrow has meetings;
- all-day events are ignored by Status calculations;
- boundary case: exactly `15m` until the next meeting shows `Next 15m`;
- boundary case: exactly `60m` until the next meeting shows `Free 1h`.

Minimum verification after implementation:

```bash
swift build
```
