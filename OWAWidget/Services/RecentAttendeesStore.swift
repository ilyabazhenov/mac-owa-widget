import Foundation

struct AttendeeRecord: Codable, Identifiable, Sendable {
    var attendee: ResolvedAttendee
    var useCount: Int
    var lastUsed: Date
    var id: String { attendee.id }
}

enum RecentAttendeesStore {
    private static let key = "frequentMeetingAttendees"
    private static let legacyKey = "recentMeetingAttendees"
    private static let maxCount = 30

    static func load(defaults: UserDefaults = .standard) -> [AttendeeRecord] {
        migrate(defaults: defaults)
        guard let data = defaults.data(forKey: key),
              let list = try? JSONDecoder().decode([AttendeeRecord].self, from: data)
        else { return [] }
        return list.sorted { lhs, rhs in
            lhs.useCount != rhs.useCount
                ? lhs.useCount > rhs.useCount
                : lhs.lastUsed > rhs.lastUsed
        }
    }

    static func record(_ attendees: [ResolvedAttendee], defaults: UserDefaults = .standard) {
        guard !attendees.isEmpty else { return }
        var current = load(defaults: defaults)
        let now = Date()
        for attendee in attendees {
            if let idx = current.firstIndex(where: { $0.attendee == attendee }) {
                current[idx].useCount += 1
                current[idx].lastUsed = now
            } else {
                current.append(AttendeeRecord(attendee: attendee, useCount: 1, lastUsed: now))
            }
        }
        current.sort { lhs, rhs in
            lhs.useCount != rhs.useCount
                ? lhs.useCount > rhs.useCount
                : lhs.lastUsed > rhs.lastUsed
        }
        let trimmed = Array(current.prefix(maxCount))
        if let data = try? JSONEncoder().encode(trimmed) {
            defaults.set(data, forKey: key)
        }
    }

    private static func migrate(defaults: UserDefaults) {
        guard defaults.data(forKey: key) == nil,
              let legacyData = defaults.data(forKey: legacyKey),
              let legacy = try? JSONDecoder().decode([ResolvedAttendee].self, from: legacyData)
        else { return }
        let now = Date()
        let records = legacy.map { AttendeeRecord(attendee: $0, useCount: 1, lastUsed: now) }
        if let data = try? JSONEncoder().encode(records) {
            defaults.set(data, forKey: key)
        }
        defaults.removeObject(forKey: legacyKey)
    }
}
