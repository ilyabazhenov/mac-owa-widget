import Foundation

/// Forces every ``SecureStore``-backed store to run its one-time migration at launch.
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

    /// Touches the stores whose migration nothing else triggers during startup.
    ///
    /// The event cache, accounts and engagement stats migrate on their own as `CalendarService`
    /// comes up, so they are deliberately absent here — reading them twice would be wasted work.
    static func runPendingMigrations() {
        _ = RecentAttendeesStore.load()
        _ = RecentLocationsStore.load()
        TrustedCertificateStore.migrateLegacyItemsIfNeeded()

        let remaining = migratedLegacyDefaultsKeys.filter {
            UserDefaults.standard.data(forKey: $0) != nil
        }
        DiagnosticLog.event("SecureStore migration pass done pendingLegacyKeys=\(remaining.count)")
    }
}
