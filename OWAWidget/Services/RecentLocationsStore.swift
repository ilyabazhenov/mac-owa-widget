import Foundation

struct LocationRecord: Codable, Identifiable, Sendable {
    var url: String
    var useCount: Int
    var lastUsed: Date
    var id: String { url }
}

enum RecentLocationsStore {
    private static let key = "meetingLocationHistory"
    private static let maxCount = 10

    static func load(defaults: UserDefaults = .standard) -> [LocationRecord] {
        guard let data = defaults.data(forKey: key),
              let list = try? JSONDecoder().decode([LocationRecord].self, from: data)
        else { return [] }
        return list.sorted { lhs, rhs in
            lhs.useCount != rhs.useCount
                ? lhs.useCount > rhs.useCount
                : lhs.lastUsed > rhs.lastUsed
        }
    }

    static func record(_ url: String, defaults: UserDefaults = .standard) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var current = load(defaults: defaults)
        let now = Date()
        if let idx = current.firstIndex(where: { $0.url == trimmed }) {
            current[idx].useCount += 1
            current[idx].lastUsed = now
        } else {
            current.append(LocationRecord(url: trimmed, useCount: 1, lastUsed: now))
        }
        current.sort { lhs, rhs in
            lhs.useCount != rhs.useCount
                ? lhs.useCount > rhs.useCount
                : lhs.lastUsed > rhs.lastUsed
        }
        let trimmedList = Array(current.prefix(maxCount))
        if let data = try? JSONEncoder().encode(trimmedList) {
            defaults.set(data, forKey: key)
        }
    }
}
