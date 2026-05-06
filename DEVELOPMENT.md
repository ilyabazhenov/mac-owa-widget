# OWA Widget Development

This document is for contributors and maintainers. User-facing installation and setup instructions live in [README.md](README.md).

## Requirements

| Requirement | Version |
|---|---|
| macOS | 13 Ventura or later |
| Swift | 6.0+ |
| Exchange / OWA | 2016, 2019, Exchange Online |

Optional tools:

- **XcodeGen** - generate `OWAWidget.xcodeproj` from `project.yml` (`brew install xcodegen`)
- **fswatch** - run `make watch` auto-rebuilds (`brew install fswatch`)
- **xcbeautify** - prettier build output (`brew install xcbeautify`)

## Build Commands

Use the commands from `Makefile`:

```bash
make build    # compile
make run      # build and launch, killing a previous instance
make watch    # auto-rebuild on .swift file changes, requires fswatch
make clean    # remove build artifacts
make kill     # stop the running instance
```

Quick compile check without bundling:

```bash
swift build
```

## Xcode Project

`OWAWidget.xcodeproj` is generated and must not be committed. Generate it from `project.yml` when needed:

```bash
xcodegen generate
open OWAWidget.xcodeproj
```

Set your **Development Team** in the project's Signing & Capabilities tab to enable code signing.

## Architecture

```text
SwiftUI Views
    |
    v
CalendarService (@MainActor, ObservableObject)
    |
    |-- CalendarProvider actors
    |       |-- OWACalendarProvider
    |       |       `-- OWAClient  (auth + REST API)
    |       `-- GoogleCalendarProvider  (stub)
    |
    |-- SyncScheduler
    `-- NotificationService
```

The project uses Swift 6 strict concurrency (`SWIFT_STRICT_CONCURRENCY = complete`). Calendar providers are actors; `CalendarEvent` and `CalendarAccount` are `Sendable` value types.

### Key Files

| File | Purpose |
|---|---|
| `OWAWidget/OWAWidgetApp.swift` | App entry point, `MenuBarExtra`, settings window, notification handler |
| `OWAWidget/Services/CalendarService.swift` | Central `@MainActor` state: accounts, events, sync status |
| `OWAWidget/Providers/CalendarProvider.swift` | Calendar provider protocol |
| `OWAWidget/Providers/OWA/OWAClient.swift` | OWA auth, cookies, CANARY token, calendar REST API |
| `OWAWidget/Providers/OWA/OWACalendarProvider.swift` | Maps OWA response to `CalendarEvent` |
| `OWAWidget/Services/MeetingURLDetector.swift` | Regex-based join URL detection |
| `OWAWidget/Services/NotificationService.swift` | Local notification scheduling |
| `OWAWidget/Services/UpdateCheckService.swift` | Sparkle update controller wrapper |
| `OWAWidget/Views/` | SwiftUI popover and settings views |

## Adding a Calendar Provider

1. Create `OWAWidget/Providers/<ProviderName>/`.
2. Implement `actor <ProviderName>CalendarProvider: CalendarProvider`.
3. Implement `fetchEvents(from:to:)` and `validateCredentials()`.
4. Add a new case to `AccountType` in `CalendarAccount.swift`.
5. Wire the provider in `CalendarService.rebuildProviders()`.
6. Add account setup UI when needed.

## Security Notes

- Passwords are stored exclusively in macOS Keychain (`com.owawidget.OWAWidget`).
- Do not commit secrets, passwords, tokens, cookies, or real private server URLs.
- `NSAllowsArbitraryLoads` is enabled for on-premise Exchange scenarios with self-signed certificates. For stricter distribution, replace this with `NSExceptionDomains` scoped to the Exchange hostname.
- `TLSBypassDelegate` accepts server trust for internal corporate servers. Treat changes around TLS validation carefully.

## Current App Version

The repository-level release version is stored in:

```bash
VERSION
```

Bump `VERSION` before preparing or publishing a new GitHub release. Do not manually edit `CFBundleShortVersionString` in `OWAWidget/Info.plist`; release packaging derives it from `VERSION`.

## Release Notes

Release notes are required and stored in:

```bash
RELEASE_NOTES.md
```

Each version section should include RU and EN notes, with install/update guidance. The release workflow fails if this file is missing or empty.

## Release Packaging

To build a release archive locally:

```bash
make release-package
```

This command builds `.build/OWAWidget.app`, creates `dist/OWAWidget-v<version>-macos.zip`, EdDSA-signs it with Sparkle's `sign_update`, and emits `dist/appcast.xml`.

The signing key is read from the login Keychain entry `https://sparkle-project.org` / account `ed25519` by default, or from the `SPARKLE_ED_PRIVATE_KEY` environment variable in CI.

To generate the keypair the first time:

```bash
bash scripts/generate_sparkle_keys.sh
```

The script prints:

- the public key, which goes into `OWAWidget/Info.plist` as `SUPublicEDKey`;
- the private key, which must be backed up in a password manager and added as the GitHub Actions secret `SPARKLE_ED_PRIVATE_KEY`.

Losing the private key means existing clients can no longer install updates signed by a new key.

## GitHub Release Flow

A manual GitHub Actions workflow is available at `.github/workflows/release.yml`.

1. Update `VERSION`.
2. Update `RELEASE_NOTES.md`.
3. Push changes to GitHub.
4. Open **Actions -> Release -> Run workflow**.

Reusing an existing version updates the same `v<version>` release tag instead of creating a new one.

The workflow builds the app, creates the zip archive, signs it through Sparkle, generates `appcast.xml`, and creates or updates a GitHub Release with tag `v<version>`. Both the zip and `appcast.xml` are uploaded as release assets so `https://github.com/<owner>/<repo>/releases/latest/download/appcast.xml` resolves to the latest published update feed.

The CI job requires `SPARKLE_ED_PRIVATE_KEY`. Without this secret, the workflow aborts to avoid shipping an unsigned build that installed clients would reject.

## Agent Release Semantics

For AI agents working in this repository:

- A request like "выпусти новый релиз" means full release publication: update `VERSION`, update `RELEASE_NOTES.md`, run `make release-package`, publish with `gh release create`.
- A request like "подготовь релиз" means prepare only: update `VERSION`, update `RELEASE_NOTES.md`, run `make release-package`, without GitHub publication unless explicitly requested.

## Contributing

Pull requests are welcome. For major changes, open an issue first to discuss the change.

When adding support for a new meeting platform, update `OWAWidget/Services/MeetingURLDetector.swift` and `OWAWidget/Models/MeetingPlatform.swift`.
