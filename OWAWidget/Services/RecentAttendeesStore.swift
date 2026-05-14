import Foundation

enum RecentAttendeesStore {
    private static let key = "recentMeetingAttendees"
    private static let maxCount = 15

    static func load() -> [ResolvedAttendee] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([ResolvedAttendee].self, from: data)
        else { return [] }
        return list
    }

    static func record(_ attendees: [ResolvedAttendee]) {
        guard !attendees.isEmpty else { return }
        var current = load()
        for attendee in attendees.reversed() {
            current.removeAll { $0 == attendee }
            current.insert(attendee, at: 0)
        }
        let trimmed = Array(current.prefix(maxCount))
        if let data = try? JSONEncoder().encode(trimmed) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
