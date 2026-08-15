import Foundation

struct AttendeeRecord: Codable, Identifiable, Sendable {
    var attendee: ResolvedAttendee
    var useCount: Int
    var lastUsed: Date
    var id: String { attendee.id }
}

/// Colleagues the user invites most often, kept for autocomplete in the compose window.
///
/// Names, addresses and job titles pulled from the corporate address book, so it is encrypted at
/// rest like everything else. Callers pass a store explicitly or get the shared one; there is no
/// `UserDefaults` parameter any more, which keeps tests from silently persisting through the
/// production key.
enum RecentAttendeesStore {
    typealias Store = SecureCodableStore<[AttendeeRecord]>

    static let storageName = "recentAttendees"
    static let legacyDefaultsKey = "frequentMeetingAttendees"
    /// Even older shape: a bare `[ResolvedAttendee]` without usage counters.
    static let olderLegacyDefaultsKey = "recentMeetingAttendees"
    private static let maxCount = 30

    static let shared: Store = makeStore()

    static func makeStore(
        secureStore: SecureStore = .shared,
        defaults: UserDefaults = .standard
    ) -> Store {
        // Fold the oldest format forward first, so the encrypted migration below sees a single
        // legacy key regardless of how far back the install goes.
        foldOlderLegacyKey(defaults: defaults)
        return Store(
            name: storageName,
            legacyKey: legacyDefaultsKey,
            store: secureStore,
            defaults: defaults,
            policy: .fallBackToLegacy
        )
    }

    static func load(store: Store = shared) -> [AttendeeRecord] {
        sorted(store.load() ?? [])
    }

    static func record(_ attendees: [ResolvedAttendee], store: Store = shared) {
        guard !attendees.isEmpty else { return }
        var current = load(store: store)
        let now = Date()
        for attendee in attendees {
            if let idx = current.firstIndex(where: { $0.attendee == attendee }) {
                current[idx].attendee = attendee
                current[idx].useCount += 1
                current[idx].lastUsed = now
            } else {
                current.append(AttendeeRecord(attendee: attendee, useCount: 1, lastUsed: now))
            }
        }
        store.save(Array(sorted(current).prefix(maxCount)))
    }

    private static func sorted(_ records: [AttendeeRecord]) -> [AttendeeRecord] {
        records.sorted { lhs, rhs in
            lhs.useCount != rhs.useCount
                ? lhs.useCount > rhs.useCount
                : lhs.lastUsed > rhs.lastUsed
        }
    }

    private static func foldOlderLegacyKey(defaults: UserDefaults) {
        guard defaults.data(forKey: legacyDefaultsKey) == nil,
              let legacyData = defaults.data(forKey: olderLegacyDefaultsKey),
              let legacy = try? JSONDecoder().decode([ResolvedAttendee].self, from: legacyData)
        else { return }
        let now = Date()
        let records = legacy.map { AttendeeRecord(attendee: $0, useCount: 1, lastUsed: now) }
        if let data = try? JSONEncoder().encode(records) {
            defaults.set(data, forKey: legacyDefaultsKey)
        }
        defaults.removeObject(forKey: olderLegacyDefaultsKey)
    }
}
