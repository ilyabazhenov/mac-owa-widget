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

struct EventCacheStore: EventCacheStoring {
    private static let currentVersion = 1

    private let userDefaults: UserDefaults
    private let key: String
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        userDefaults: UserDefaults = .standard,
        key: String = "cachedCalendarEventsV1"
    ) {
        self.userDefaults = userDefaults
        self.key = key

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        self.decoder = decoder
    }

    func load() -> EventCacheSnapshot? {
        guard let data = userDefaults.data(forKey: key) else { return nil }
        guard let snapshot = try? decoder.decode(EventCacheSnapshot.self, from: data) else { return nil }
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
        guard let data = try? encoder.encode(snapshot) else { return }
        userDefaults.set(data, forKey: key)
    }

    func clear() {
        userDefaults.removeObject(forKey: key)
    }
}
