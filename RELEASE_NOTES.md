## What's Changed

- Improved KTalk meeting link detection when links are provided without scheme (for example, `acme.ktalk.ru/room` now resolves correctly).
- Added URL normalization to `https://` for matched KTalk links without explicit protocol.
- Extended tests for KTalk URL detection in plain text and HTML content.

## Installation

1. Move `OWAWidget.app` to `/Applications`.
2. Remove quarantine attributes:

```bash
xattr -dr com.apple.quarantine /Applications/OWAWidget.app
```
