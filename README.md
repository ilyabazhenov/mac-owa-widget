# OWA Widget

A macOS menu bar app for quick access to your upcoming meetings from a Microsoft Exchange / OWA calendar. One click to join Teams, Zoom, Webex, Google Meet, or any other video platform.

![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue)
![Swift 6](https://img.shields.io/badge/Swift-6-orange)
![License: MIT](https://img.shields.io/badge/License-MIT-green)

## Features

- **Live meeting banner** — the next meeting is always front and center with a one-click Join button
- **Conflict detection** — multiple meetings starting at the same time are grouped in a stack
- **Smart URL detection** — finds join links in the dedicated field, location, and meeting body
- **Platform icons** — Teams, Zoom, Webex, Google Meet, KTalk and more
- **Local notifications** — get notified N minutes before a meeting starts; tap Join to open the call
- **Secure storage** — passwords are stored in the macOS Keychain, never in plain text
- **Scheduled sync** — calendar syncs automatically on a configurable interval
- **Multiple accounts** — add as many Exchange accounts as you need
- **On-premise friendly** — works with self-signed TLS certificates for internal Exchange servers

---

## Requirements

| Requirement | Version |
|---|---|
| macOS | 13 Ventura or later |
| Swift | 6.0+ |
| Exchange / OWA | 2016, 2019, Exchange Online |

Optional tools:
- **XcodeGen** — to generate `OWAWidget.xcodeproj` (`brew install xcodegen`)
- **fswatch** — for `make watch` auto-rebuild (`brew install fswatch`)
- **xcbeautify** — for prettier build output (`brew install xcbeautify`)

---

## Installation

### Build from source

```bash
git clone https://github.com/ilyabazhenov/mac-owa-widget.git
cd mac-owa-widget
make run
```

The app will appear in the menu bar. No Dock icon — it's menu bar only.

### Run unsigned app build

If macOS blocks an unsigned build (downloaded from Releases or built locally), remove the quarantine attribute and launch:

```bash
xattr -dr com.apple.quarantine /Applications/OWAWidget.app
open /Applications/OWAWidget.app
```

### Generate Xcode project (optional)

`OWAWidget.xcodeproj` is not stored in the repository (it's a generated artifact). To open the project in Xcode:

```bash
xcodegen generate
open OWAWidget.xcodeproj
```

Set your **Development Team** in the project's Signing & Capabilities tab to enable code signing.

---

## Getting Started

### 1. Find your OWA server URL

Your OWA URL is the address you use to access corporate email in the browser. It typically looks like:

```
https://mail.yourcompany.com
https://owa.yourcompany.com
https://outlook.yourcompany.com
```

Ask your IT department if you're not sure. The app connects to `/owa/` on that server.

> **VPN**: If your Exchange server is on-premise and not internet-facing, make sure you're connected to the corporate VPN before syncing.

### 2. Add your account

1. Click the menu bar icon → **Settings** (⚙)
2. Go to the **Account** tab → click **+**
3. Fill in:
   - **Display name** — any label (e.g. "Work")
   - **Server URL** — your OWA URL (e.g. `https://mail.company.com`)
   - **Email** — your corporate email address
   - **Password** — your Windows / Active Directory password
4. Click **Test Connection** to verify
5. Click **Save**

The widget will sync immediately and show your upcoming meetings.

### 3. Configure notifications

Go to **Settings → Preferences** to set:
- **Sync interval** — how often to fetch new events (default: 5 min)
- **Notification lead time** — how many minutes before a meeting to send a notification (default: 10 min)

Allow notifications when macOS prompts you on first launch.

---

## Build commands

```bash
make build    # compile
make run      # build and launch (kills previous instance)
make watch    # auto-rebuild on .swift file changes (requires fswatch)
make clean    # remove build artifacts
make kill     # stop the running instance
```

Quick compile check without bundling:

```bash
swift build
```

### Current app version

The repository-level release version is stored in:

```bash
VERSION
```

This is a mandatory release-prep step: bump `VERSION` to a new value before triggering a new GitHub release.

### Release description (required)

Release notes are required and stored in:

```bash
RELEASE_NOTES.md
```

The release workflow fails if this file is missing or empty.

### Release packaging

To build a release archive locally:

```bash
make release-package
```

This command builds `.build/OWAWidget.app` and creates `dist/OWAWidget-v<version>-macos.zip`.

### GitHub release flow

A manual GitHub Actions workflow is available at `.github/workflows/release.yml`.

1. Update `VERSION`
2. Update `RELEASE_NOTES.md`
3. Push changes to GitHub
4. Open **Actions → Release → Run workflow**

> `VERSION` bump is required for each release. Reusing an existing version will overwrite/update the same `v<version>` release tag instead of creating a new release.

The workflow builds the app, creates the zip archive, then creates (or updates) a GitHub Release with tag `v<version>` and publishes the text from `RELEASE_NOTES.md` as release description.

### Agent release command semantics

For AI agents working in this repository:

- Request like "выпусти новый релиз" means full release publication flow: update `VERSION`, update `RELEASE_NOTES.md`, run `make release-package`, publish with `gh release create`.
- Request like "подготовь релиз" means prepare only: update `VERSION`, update `RELEASE_NOTES.md`, run `make release-package`, without GitHub publication unless explicitly asked.

---

## Architecture

```
SwiftUI Views
    │
    ▼
CalendarService (@MainActor, ObservableObject)
    │
    ├── CalendarProvider actors
    │       ├── OWACalendarProvider
    │       │       └── OWAClient  (auth + REST API)
    │       └── GoogleCalendarProvider  (stub)
    │
    ├── SyncScheduler
    └── NotificationService
```

The project uses **Swift 6 strict concurrency** (`SWIFT_STRICT_CONCURRENCY = complete`). Each calendar provider is an actor; `CalendarEvent` and `CalendarAccount` are `Sendable` value types.

### Key files

| File | Purpose |
|---|---|
| `OWAWidget/OWAWidgetApp.swift` | App entry point, `MenuBarExtra`, settings window, notification handler |
| `OWAWidget/Services/CalendarService.swift` | Central `@MainActor` state: accounts, events, sync status |
| `OWAWidget/Providers/CalendarProvider.swift` | Calendar provider protocol |
| `OWAWidget/Providers/OWA/OWAClient.swift` | OWA auth, cookies, CANARY token, calendar REST API |
| `OWAWidget/Providers/OWA/OWACalendarProvider.swift` | Maps OWA response to `CalendarEvent` |
| `OWAWidget/Services/MeetingURLDetector.swift` | Regex-based join URL detection |
| `OWAWidget/Services/NotificationService.swift` | Local notification scheduling |
| `OWAWidget/Views/` | SwiftUI popover and settings views |

### Adding a new calendar provider

1. Create `OWAWidget/Providers/<ProviderName>/`
2. Implement `actor <ProviderName>CalendarProvider: CalendarProvider`
3. Implement `fetchEvents(from:to:)` and `validateCredentials()`
4. Add a new case to `AccountType` in `CalendarAccount.swift`
5. Wire it up in `CalendarService.rebuildProviders()`
6. Add account setup UI if needed

---

## Security

- Passwords are stored exclusively in the macOS Keychain (`com.owawidget.OWAWidget`)
- `NSAllowsArbitraryLoads` is enabled to support on-premise Exchange servers with self-signed certificates. For Mac App Store distribution, replace with `NSExceptionDomains` scoped to your Exchange hostname
- The TLS bypass delegate (`TLSBypassDelegate`) accepts any server trust — intended for internal corporate servers only

---

## Contributing

Pull requests are welcome. For major changes, please open an issue first to discuss what you would like to change.

When adding support for a new meeting platform, update `MeetingURLDetector.swift` and `MeetingPlatform.swift`.

---

## License

[MIT](LICENSE)
