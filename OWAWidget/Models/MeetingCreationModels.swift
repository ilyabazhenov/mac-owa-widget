import Foundation

struct ResolvedAttendee: Identifiable, Hashable, Sendable, Codable {
    var id: String { email }
    let displayName: String
    let email: String
    let jobTitle: String?

    func hash(into hasher: inout Hasher) { hasher.combine(email) }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.email == rhs.email }
}

struct AttendeeAvailability: Sendable {
    let email: String
    let mergedFreeBusy: String  // "002200..." 30-мин интервалы: 0=free, 1=tentative, 2=busy, 3=OOF
    let windowStart: Date
    let intervalMinutes: Int    // 30
}

struct FreeSlot: Identifiable, Sendable {
    let id: UUID
    let start: Date
    let end: Date

    init(start: Date, end: Date) {
        self.id = UUID()
        self.start = start
        self.end = end
    }
}

struct MeetingDraft: Sendable {
    var title: String = ""
    var attendees: [ResolvedAttendee] = []
    var durationMinutes: Int = 30
    var searchRange: MeetingSearchRange = .thisWeek
}

enum MeetingSearchRange: String, CaseIterable, Sendable {
    case today, tomorrow, thisWeek, nextWeek

    var dateInterval: DateInterval {
        dateInterval(referenceNow: Date())
    }

    /// Same as `dateInterval` but with a fixed "now" for tests and previews.
    func dateInterval(referenceNow: Date) -> DateInterval {
        let cal = AppTimeZone.calendar
        let todayStart = cal.startOfDay(for: referenceNow)
        switch self {
        case .today:
            let end = cal.date(bySettingHour: 18, minute: 0, second: 0, of: todayStart)!
            return DateInterval(start: max(referenceNow, todayStart), end: end)
        case .tomorrow:
            let start = cal.date(byAdding: .day, value: 1, to: todayStart)!
            let end = cal.date(bySettingHour: 18, minute: 0, second: 0, of: start)!
            return DateInterval(start: start, end: end)
        case .thisWeek:
            let end = cal.date(byAdding: .day, value: 5, to: todayStart)!
            let endOfWeek = cal.date(bySettingHour: 18, minute: 0, second: 0, of: end)!
            return DateInterval(start: max(referenceNow, todayStart), end: endOfWeek)
        case .nextWeek:
            let start = cal.date(byAdding: .day, value: 7, to: todayStart)!
            let end = cal.date(byAdding: .day, value: 12, to: todayStart)!
            let endOfNextWeek = cal.date(bySettingHour: 18, minute: 0, second: 0, of: end)!
            return DateInterval(start: start, end: endOfNextWeek)
        }
    }

    var localizationKey: String {
        switch self {
        case .today:    return "meeting.range.today"
        case .tomorrow: return "meeting.range.tomorrow"
        case .thisWeek: return "meeting.range.this.week"
        case .nextWeek: return "meeting.range.next.week"
        }
    }
}

enum MeetingDurationOption: Int, CaseIterable, Sendable {
    case min15 = 15
    case min30 = 30
    case min45 = 45
    case min60 = 60

    var localizationKey: String {
        switch self {
        case .min15: return "meeting.duration.15min"
        case .min30: return "meeting.duration.30min"
        case .min45: return "meeting.duration.45min"
        case .min60: return "meeting.duration.60min"
        }
    }
}
