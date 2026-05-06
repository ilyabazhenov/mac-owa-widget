## What's Changed

- Improved category color mapping by adding support for lilac/violet naming variants (`Лиловая категория`, `lilac`, `violet`) to ensure consistent purple accents.
- Added regression test coverage for lilac category mapping in `MeetingAccentColorResolverTests`.
- Preserved fallback behavior to platform colors when a category has no known color mapping.

## Installation

1. Move `OWAWidget.app` to `/Applications`.
2. Remove quarantine attributes:

```bash
xattr -dr com.apple.quarantine /Applications/OWAWidget.app
```
