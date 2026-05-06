## What's Changed

- Added category-aware accent colors for meeting cards and banners, with fallback to platform colors when no category color is recognized.
- Improved cancelled meeting styling and behavior consistency via effective cancellation detection in UI actions and summaries.
- Added tests for category color mapping and retained full test-suite coverage for release safety.

## Installation

1. Move `OWAWidget.app` to `/Applications`.
2. Remove quarantine attributes:

```bash
xattr -dr com.apple.quarantine /Applications/OWAWidget.app
```
