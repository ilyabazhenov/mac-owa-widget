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
    var agenda: String = ""
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
            guard let dayEnd = cal.date(bySettingHour: 18, minute: 0, second: 0, of: todayStart) else {
                return DateInterval(start: referenceNow, duration: 0)
            }
            let rawStart = max(referenceNow, todayStart)
            // After end-of-workday, `rawStart > dayEnd` would make an invalid `DateInterval` (trap in Swift).
            let start = min(rawStart, dayEnd)
            return DateInterval(start: start, end: dayEnd)
        case .tomorrow:
            guard let start = cal.date(byAdding: .day, value: 1, to: todayStart),
                  let end = cal.date(bySettingHour: 18, minute: 0, second: 0, of: start)
            else {
                return DateInterval(start: referenceNow, duration: 0)
            }
            return DateInterval(start: start, end: end)
        case .thisWeek:
            guard let endDay = cal.date(byAdding: .day, value: 5, to: todayStart),
                  let endOfWeek = cal.date(bySettingHour: 18, minute: 0, second: 0, of: endDay)
            else {
                return DateInterval(start: referenceNow, duration: 0)
            }
            let rawStart = max(referenceNow, todayStart)
            let start = min(rawStart, endOfWeek)
            return DateInterval(start: start, end: endOfWeek)
        case .nextWeek:
            // Must match `slotGridWeekInterval`: the grid is the **calendar** next week (Mon-first),
            // while a naive "+7 days from today" window starts mid-week and leaves Mon–Wed columns empty.
            let gridCal = Self.slotGridCalendar
            let week = slotGridWeekInterval(referenceNow: referenceNow)
            let monday = gridCal.startOfDay(for: week.start)
            guard let friday = gridCal.date(byAdding: .day, value: 4, to: monday),
                  let dayEnd = gridCal.date(bySettingHour: 18, minute: 0, second: 0, of: friday)
            else {
                return DateInterval(start: referenceNow, duration: 0)
            }
            return DateInterval(start: monday, end: dayEnd)
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

    /// Monday-based calendar week (`AppTimeZone`) used as slot-grid columns: current week for
    /// today / tomorrow / thisWeek, and the **following** calendar week for nextWeek.
    func slotGridWeekInterval(referenceNow: Date = Date()) -> DateInterval {
        let cal = Self.slotGridCalendar
        let todayStart = cal.startOfDay(for: referenceNow)
        let anchor: Date
        switch self {
        case .today, .thisWeek:
            anchor = referenceNow
        case .tomorrow:
            anchor = cal.date(byAdding: .day, value: 1, to: todayStart) ?? referenceNow
        case .nextWeek:
            guard let currentWeek = cal.dateInterval(of: .weekOfYear, for: referenceNow),
                  let inNextWeek = cal.date(byAdding: .day, value: 7, to: currentWeek.start),
                  let nextWeek = cal.dateInterval(of: .weekOfYear, for: inNextWeek)
            else {
                return cal.dateInterval(of: .weekOfYear, for: referenceNow)
                    ?? DateInterval(start: todayStart, duration: 86400 * 7)
            }
            return nextWeek
        }
        return cal.dateInterval(of: .weekOfYear, for: anchor)
            ?? DateInterval(start: todayStart, duration: 86400 * 7)
    }

    private static var slotGridCalendar: Calendar {
        var cal = AppTimeZone.calendar
        cal.firstWeekday = 2 // Monday — match typical RU/EU “рабочая неделя”
        return cal
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

extension DateInterval {
    /// Each Monday–Friday `startOfDay` in `cal` that lies in `[start, end)` (half-open by `end`).
    func weekdayColumnStartDates(calendar cal: Calendar) -> [Date] {
        var days: [Date] = []
        var d = cal.startOfDay(for: start)
        while d < end {
            let wd = cal.component(.weekday, from: d)
            if wd != 1, wd != 7 {
                days.append(d)
            }
            guard let next = cal.date(byAdding: .day, value: 1, to: d) else { break }
            d = next
        }
        return days
    }
}
