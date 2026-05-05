## What's Changed

- Fixed crash when launching the app binary directly from `/Applications/OWAWidget.app/Contents/MacOS/OWAWidget`.
- Removed runtime dependency on SwiftPM-generated resource bundle accessor for app localization loading.
- Improved app bundling paths to resolve binary/resource locations via `swift build --show-bin-path`.
- Ensured bundle assembly cleans stale root-level resource bundle artifacts before codesigning.
