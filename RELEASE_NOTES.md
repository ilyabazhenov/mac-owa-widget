## What's Changed

- Fixed KTalk join-link extraction from OWA events by scanning all available body fields and handling escaped URL payloads.
- Added GetCalendarView debug dump support to inspect full raw OWA responses when troubleshooting parsing issues.
- Added meeting metadata support for `IsCancelled`, `IsOrganizer`, and `Categories`, including UI updates and cancellation-aware behavior for banners and reminders.
- Improved cancelled-meeting detection fallback for legacy/cached items with `Отменено:` / `Cancelled:` subject prefixes.

## Installation

1. Move `OWAWidget.app` to `/Applications`.
2. Remove quarantine attributes:

```bash
xattr -dr com.apple.quarantine /Applications/OWAWidget.app
```
