import Foundation

/// Forces every ``SecureStore``-backed store to run its one-time migration at launch, and clears
/// out what earlier versions left on disk in cleartext.
///
/// Migration is lazy by design — each store converts itself on first read. That is fine for the
/// event cache and the account list, which are read during startup anyway, but the compose-window
/// histories (attendees, locations) are only touched when the user opens that window. Left to
/// themselves they could sit in the cleartext preferences plist for months on an install where
/// nobody creates meetings from the widget, which defeats the point of encrypting at all.
///
/// Runs once per launch, off the main actor: each store is a few kilobytes, but there is no reason
/// to make the menu bar wait for the encryption.
enum SecureStoreMigrator {
    /// Names of every store that owns a cleartext predecessor, for tests and diagnostics.
    static let migratedLegacyDefaultsKeys = [
        EventCacheStore.legacyDefaultsKey,
        "calendarAccounts",
        RecentAttendeesStore.legacyDefaultsKey,
        RecentAttendeesStore.olderLegacyDefaultsKey,
        RecentLocationsStore.legacyDefaultsKey,
        MeetingEngagementStatsService.legacyDefaultsKey
    ]

    /// Directories written before traces were encrypted, relative to the app's Application Support
    /// folder. Both predate the move to bundle-id-scoped paths, so nothing current writes to them.
    ///
    /// `owa-debug` is the one that matters: it held raw `GetCalendarView` responses — every meeting
    /// title, attendee and agenda in the mailbox — as 0644 files in a 0755 directory. Only an
    /// install that switched on the hidden `debugDumpGetCalendarViewResponse` default ever had it,
    /// which is rare, but for those it accumulated indefinitely with nothing ever cleaning up.
    /// `debug` only ever existed in DEBUG builds.
    static let legacyCleartextDirectories = ["owa-debug", "debug"]

    /// Touches the stores whose migration nothing else triggers during startup.
    ///
    /// The event cache, accounts and engagement stats migrate on their own as `CalendarService`
    /// comes up, so they are deliberately absent here — reading them twice would be wasted work.
    /// Trusted certificates are deliberately absent: their legacy copy lives in the Keychain, not
    /// in cleartext on disk, and reading it needs an authorization dialog. Draining it from here
    /// put that dialog seconds after launch with nothing on screen to explain it — and back every
    /// launch until accepted. ``TrustedCertificateStore`` migrates itself on first use instead,
    /// during TLS validation for the pinned host, where the prompt at least coincides with a sync.
    static func runPendingMigrations() {
        _ = RecentAttendeesStore.load()
        _ = RecentLocationsStore.load()

        let remaining = migratedLegacyDefaultsKeys.filter {
            UserDefaults.standard.data(forKey: $0) != nil
        }
        DiagnosticLog.event("SecureStore migration pass done pendingLegacyKeys=\(remaining.count)")

        removeLegacyCleartextDebugDirectories()
    }

    /// Production entry point for the cleanup. Guarded so the suite never deletes anything under
    /// the developer's real Application Support.
    static func removeLegacyCleartextDebugDirectories() {
        guard !SecureStore.isRunningTests else { return }
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) else { return }

        let removed = removeLegacyCleartextDirectories(
            under: base.appendingPathComponent("OWAWidget", isDirectory: true)
        )
        if removed > 0 {
            DiagnosticLog.event("SecureStore removed legacy cleartext directories=\(removed)")
        }
    }

    /// Deletes the known legacy directories under `root`, returning how many were removed.
    ///
    /// Takes the root as a parameter so this can be exercised against a temporary tree. Only the
    /// two hard-coded names are ever touched, and only when they are directories — nothing here
    /// walks or guesses.
    @discardableResult
    static func removeLegacyCleartextDirectories(
        under root: URL,
        fileManager: FileManager = .default
    ) -> Int {
        var removed = 0
        for name in legacyCleartextDirectories {
            let directory = root.appendingPathComponent(name, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else { continue }

            do {
                try fileManager.removeItem(at: directory)
                removed += 1
            } catch {
                DiagnosticLog.event("SecureStore failed to remove legacy directory \(name)")
            }
        }
        return removed
    }
}
