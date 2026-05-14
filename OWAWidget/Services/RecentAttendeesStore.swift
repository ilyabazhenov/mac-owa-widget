import Foundation

enum RecentAttendeesStore {
    private static let key = "recentMeetingAttendees"
    private static let maxCount = 15

    static func load(defaults: UserDefaults = .standard) -> [ResolvedAttendee] {
        guard let data = defaults.data(forKey: key),
              let list = try? JSONDecoder().decode([ResolvedAttendee].self, from: data)
        else { return [] }
        return list
    }

    static func record(_ attendees: [ResolvedAttendee], defaults: UserDefaults = .standard) {
        guard !attendees.isEmpty else { return }
        var current = load(defaults: defaults)
        for attendee in attendees.reversed() {
            current.removeAll { $0 == attendee }
            current.insert(attendee, at: 0)
        }
        let trimmed = Array(current.prefix(maxCount))
        if let data = try? JSONEncoder().encode(trimmed) {
            defaults.set(data, forKey: key)
        }
    }
}
