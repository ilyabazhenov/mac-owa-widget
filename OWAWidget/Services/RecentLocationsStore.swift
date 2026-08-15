import Foundation

struct LocationRecord: Codable, Identifiable, Sendable {
    var url: String
    var useCount: Int
    var lastUsed: Date
    var id: String { url }
}

/// Meeting rooms and conference links the user has typed before, offered as suggestions when
/// composing. Encrypted at rest: the entries are internal room names and call URLs.
enum RecentLocationsStore {
    typealias Store = SecureCodableStore<[LocationRecord]>

    static let storageName = "recentLocations"
    static let legacyDefaultsKey = "meetingLocationHistory"
    private static let maxCount = 10

    static let shared: Store = makeStore()

    static func makeStore(
        secureStore: SecureStore = .shared,
        defaults: UserDefaults = .standard
    ) -> Store {
        Store(
            name: storageName,
            legacyKey: legacyDefaultsKey,
            store: secureStore,
            defaults: defaults,
            policy: .fallBackToLegacy
        )
    }

    static func load(store: Store = shared) -> [LocationRecord] {
        sorted(store.load() ?? [])
    }

    static func record(_ url: String, store: Store = shared) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var current = load(store: store)
        let now = Date()
        if let idx = current.firstIndex(where: { $0.url == trimmed }) {
            current[idx].useCount += 1
            current[idx].lastUsed = now
        } else {
            current.append(LocationRecord(url: trimmed, useCount: 1, lastUsed: now))
        }
        store.save(Array(sorted(current).prefix(maxCount)))
    }

    private static func sorted(_ records: [LocationRecord]) -> [LocationRecord] {
        records.sorted { lhs, rhs in
            lhs.useCount != rhs.useCount
                ? lhs.useCount > rhs.useCount
                : lhs.lastUsed > rhs.lastUsed
        }
    }
}
