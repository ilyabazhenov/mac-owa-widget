## What's Changed

- Added a clearer quick return action to Today in the day navigation header.
- Updated the date navigation UX so "Today" is recognized as an action, not part of the date label.
- Added regression tests for day navigation bounds and visibility rules of the "Today" action.

## Installation

1. Move `OWAWidget.app` to `/Applications`.
2. Remove quarantine attributes:

```bash
xattr -dr com.apple.quarantine /Applications/OWAWidget.app
```
