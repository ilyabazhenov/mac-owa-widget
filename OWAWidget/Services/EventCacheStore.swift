import Foundation

protocol EventCacheStoring {
    func load() -> EventCacheSnapshot?
    func save(events: [CalendarEvent], rangeStart: Date, rangeEnd: Date)
    func clear()
}

struct EventCacheSnapshot: Codable, Sendable, Equatable {
    let version: Int
    let savedAt: Date
    let rangeStart: Date
    let rangeEnd: Date
    let events: [CalendarEvent]
}

/// Offline snapshot of the calendar, encrypted at rest.
///
/// This is the most sensitive thing the app persists — meeting titles, locations, attendee
/// addresses, full agendas and join URLs that frequently embed conference secrets — so it moved
/// out of the cleartext preferences plist into ``SecureStore``. The failure policy is
/// `.treatAsEmpty`: an unreadable container costs a cold start with no cache and nothing more,
/// because the next sync rebuilds it from the server.
struct EventCacheStore: EventCacheStoring {
    private static let currentVersion = 1
    static let storageName = "events"
    static let legacyDefaultsKey = "cachedCalendarEventsV1"

    private let backing: SecureCodableStore<EventCacheSnapshot>

    init(
        secureStore: SecureStore = .shared,
        userDefaults: UserDefaults = .standard,
        name: String = EventCacheStore.storageName,
        legacyKey: String? = EventCacheStore.legacyDefaultsKey
    ) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970

        self.backing = SecureCodableStore(
            name: name,
            legacyKey: legacyKey,
            store: secureStore,
            defaults: userDefaults,
            policy: .treatAsEmpty,
            encoder: encoder,
            decoder: decoder
        )
    }

    func load() -> EventCacheSnapshot? {
        guard let snapshot = backing.load() else { return nil }
        guard snapshot.version == Self.currentVersion else { return nil }
        return snapshot
    }

    func save(events: [CalendarEvent], rangeStart: Date, rangeEnd: Date) {
        let snapshot = EventCacheSnapshot(
            version: Self.currentVersion,
            savedAt: Date(),
            rangeStart: rangeStart,
            rangeEnd: rangeEnd,
            events: events
        )
        backing.save(snapshot)
    }

    func clear() {
        backing.clear()
    }
}
