## What's Changed

- Added separate bundle identifiers for local development and release packaging to avoid LaunchServices conflicts (`.dev` for `make run/watch`, production id for release).
- Rebranded user-facing app naming to **Mac Owa Widget** across bundle metadata and localizations.
- Updated agent instructions so "release new version" runs the full release flow (version bump, notes update, archive build, GitHub publication).
