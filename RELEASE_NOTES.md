## What's Changed

- Added offline mode with persisted event cache, so meetings remain visible during connection loss and after app restart.
- Improved popover resilience for offline/error states and added targeted coverage for cache restore and sync fallback flows.
- Stabilized next-meeting banner rendering by removing perpetual pulse animation that could trigger visual jitter in the dropdown.
- Included app icon packaging updates for local bundle assembly (`AppIcon.icns` copy in `Makefile` and `Info.plist` icon binding).
