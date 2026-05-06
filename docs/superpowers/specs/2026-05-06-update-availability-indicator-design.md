# Update availability indicator — design

**Date:** 2026-05-06  
**Status:** Approved for implementation

## Goal

Show a passive indicator in the meeting popover when a newer stable release exists on GitHub (`ilyabazhenov/mac-owa-widget`). User opens the release page in the browser; installation stays manual. No backend, no telemetry, no Sparkle.

## Non-goals

- In-app download/install of updates
- User install IDs or analytics
- Sparkle or other auto-update frameworks

## Behavior

- **Source:** `GET https://api.github.com/repos/ilyabazhenov/mac-owa-widget/releases/latest` (anonymous, `User-Agent` set).
- **Throttle:** At most one automatic fetch every **6 hours** (persist last attempt time to avoid storms on errors).
- **Manual:** “Check now” in Preferences always attempts a fetch (unless a check is already in progress), regardless of automatic toggle.
- **Automatic toggle:** When off, no periodic timer and no automatic fetch on launch; cached state still drives the banner if a newer version was already known.
- **Banner:** Shown in popover above the meeting list when `compareVersions(cachedLatest, currentApp) == .orderedDescending` and `cachedLatest != skippedVersion`.
- **Actions:** “Open release” opens `html_url`; “Skip” stores `skippedVersion` until a newer GitHub version appears.
- **Ignore:** `draft == true` or `prerelease == true` responses (defensive; `/latest` is non-prerelease in normal cases).

## Version comparison

- Normalize: trim, strip leading `v` / `V`.
- Split by `.`; each segment: leading integer (default `0` if absent), optional non-numeric suffix; pure numeric segment sorts **after** same number with suffix (release > prerelease for that segment).
- Malformed / incomparable pairs fall back to `.orderedSame` to avoid false positives.

## Persistence (UserDefaults)

| Key | Purpose |
|-----|---------|
| `updateCheck.automaticChecksEnabled` | Bool, default `true` — periodic checks |
| `updateCheck.lastCheckAttemptAt` | Date — throttle automatic fetches |
| `updateCheck.skippedVersion` | String — dismissed banner version |
| `updateCheck.cachedLatestVersion` | String |
| `updateCheck.cachedLatestURL` | String |
| `updateCheck.cachedLatestPublishedAt` | TimeInterval since reference date (or ISO string) |

## UI

- **Popover:** Compact banner row (icon + version label + open + dismiss).
- **Preferences:** Section “Updates”: automatic toggle, hint text, “Check now” (disabled while `isChecking`).

## Localization

RU/EN keys under `update.banner.*` and `preferences.updates.*`.

## Testing

- Unit tests for version normalization and comparison (`@testable import OWAWidget`).
- Manual: `make run` with lowered `CFBundleShortVersionString` / `VERSION` to force banner.
