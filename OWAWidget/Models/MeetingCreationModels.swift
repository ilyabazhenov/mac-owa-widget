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
    /// 0.0–1.0; 1.0 is earlier in the day (9:00), 0.0 is later (18:00).
    /// Used as a ranking factor and to colour the heat map.
    let score: Double

    init(start: Date, end: Date, score: Double = 0.0) {
        self.id = UUID()
        self.start = start
        self.end = end
        self.score = score
    }
}

struct AttendeeSlotStatus: Sendable {
    let displayName: String
    let rawChar: Character  // '0' free, '1' tentative, '2' busy, '3' OOF
    /// Titles of all overlapping events. Multiple meetings can land in the same 30-min
    /// cell — keep them all so the tooltip can list every conflict, not just the first.
    let eventTitles: [String]

    init(displayName: String, rawChar: Character, eventTitles: [String] = []) {
        self.displayName = displayName
        self.rawChar = rawChar
        self.eventTitles = eventTitles
    }
}

enum SlotAvailabilityState: Sendable {
    case free(score: Double)
    case tentative
    case busy
    case outOfOffice

    /// The worst status among attendees.
    ///
    /// `4` means “no data” (`[MS-OXWAVLS]`), not a busy level, so it must be removed
    /// **before** taking the maximum. Otherwise it breaks the result: lexically, `"4" > "3" > "2"`,
    /// so one attendee without published availability could override genuinely busy attendees
    /// and colour the slot green as “Free”. Exchange routinely sends fours for mailboxes whose
    /// availability it does not expose, so this occurred before the ActiveSync provider existed.
    ///
    /// Slot selection was unaffected: `MeetingFreeSlotCalculator` requires exactly `"0"` and
    /// does not consider unknown availability free. Only the grid rendering was affected.
    static func aggregate(from chars: [Character]) -> SlotAvailabilityState {
        let known = chars.filter { $0 != "4" }
        // Empty means no participant has published availability. The cell stays non-clickable:
        // the calculator will not offer such a slot.
        guard let worst = known.max() else { return .free(score: 0) }
        switch worst {
        case "3": return .outOfOffice
        case "2": return .busy
        case "1": return .tentative
        default:  return .free(score: 0)
        }
    }
}

/// A row position inside a multi-line free slot.
enum FreeSlotPosition: Sendable {
    case single   // 30-мин слот — одна строка, скругление со всех сторон
    case start    // первая строка многострочного слота — скругление сверху
    case middle   // промежуточная строка — без скруглений
    case end      // последняя строка — скругление снизу
}

struct CellAvailability: Sendable {
    let state: SlotAvailabilityState
    let attendeeStatuses: [AttendeeSlotStatus]
    /// Optional-attendee statuses for this cell. They do NOT affect the cell `state` or colour;
    /// they appear only in the hover tooltip, so the organizer can see which optional attendees
    /// are busy in an otherwise suitable slot.
    let optionalAttendeeStatuses: [AttendeeSlotStatus]
    /// Non-nil means the cell represents a free slot and is clickable.
    let freeSlot: FreeSlot?
    var slotPosition: FreeSlotPosition = .single
    /// The free cell belongs to a continuous window long enough for the selected meeting
    /// duration. If `false`, everyone is free but no full slot fits here (a short gap), so the
    /// grid renders it muted without “Free”.
    var fitsDuration: Bool = true
}

enum AttendeeKind: Sendable, Hashable {
    case required
    case optional
}

struct MeetingDraft: Sendable {
    var title: String = ""
    var agenda: String = ""
    var location: String = ""
    var requiredAttendees: [ResolvedAttendee] = []
    var optionalAttendees: [ResolvedAttendee] = []
    /// Monday (`startOfDay`) of the selected week. Slot search covers that week's Mon–Fri.
    var selectedWeekStart: Date = MeetingDraft.mondayOfWeek(containing: Date())
    /// Desired meeting duration in minutes. Search looks for windows of exactly that length
    /// (`MeetingFreeSlotCalculator` takes ceil(duration/30) adjacent free cells).
    var durationMinutes: Int = 30

    /// Available duration presets for chips in the create-meeting window.
    static let durationPresets = [30, 60, 90, 120]

    var allAttendees: [ResolvedAttendee] {
        requiredAttendees + optionalAttendees
    }

    func kind(of attendee: ResolvedAttendee) -> AttendeeKind? {
        if requiredAttendees.contains(attendee) { return .required }
        if optionalAttendees.contains(attendee) { return .optional }
        return nil
    }

    /// Stable key for debounced slot auto-refresh (`CreateMeetingViewModel`).
    /// Only required attendees participate in slot search (v1), so optional list is excluded
    /// to avoid useless re-fetches when only optional participants change.
    var slotAutoRefreshKey: String {
        requiredAttendees.map(\.email).sorted().joined(separator: "\u{1e}")
            + "|\(Int(selectedWeekStart.timeIntervalSince1970))"
            + "|d\(durationMinutes)"
    }

    /// Stable key for invalidating `CreateMeetingViewModel.cellMatrix`.
    /// Includes both attendee groups (optional attendees affect the grid tooltip) and the selected week.
    /// title / agenda / location are NOT included because they do not affect matrix contents.
    var cellMatrixSignature: String {
        let req = requiredAttendees.map(\.email).sorted().joined(separator: ",")
        let opt = optionalAttendees.map(\.email).sorted().joined(separator: ",")
        return "\(req)|\(opt)|\(Int(selectedWeekStart.timeIntervalSince1970))|d\(durationMinutes)"
    }

    /// Slot-search interval: Mon 00:00 → Fri 18:00 of the selected week. For the **current** week
    /// (`referenceNow` falls between Monday and Friday at 18:00), its start is clamped to
    /// `referenceNow` to avoid offering past slots. The interval is empty after Friday ends.
    func dateInterval(referenceNow: Date = Date()) -> DateInterval {
        let cal = MeetingDraft.weekCalendar
        let monday = cal.startOfDay(for: selectedWeekStart)
        guard let friday = cal.date(byAdding: .day, value: 4, to: monday),
              let dayEnd = cal.date(bySettingHour: 18, minute: 0, second: 0, of: friday)
        else {
            return DateInterval(start: monday, duration: 0)
        }
        // Past weeks have an empty interval; there is nothing to search in the past.
        if dayEnd <= referenceNow {
            return DateInterval(start: dayEnd, duration: 0)
        }
        // For the current week, do not start before referenceNow.
        let rawStart = max(monday, referenceNow)
        let start = min(rawStart, dayEnd)
        return DateInterval(start: start, end: dayEnd)
    }

    /// Calendar week (Mon–Sun) containing the selected date; it provides the Mon–Fri column grid.
    func slotGridWeekInterval(referenceNow: Date = Date()) -> DateInterval {
        let cal = MeetingDraft.weekCalendar
        let monday = cal.startOfDay(for: selectedWeekStart)
        guard let weekEnd = cal.date(byAdding: .day, value: 7, to: monday) else {
            return DateInterval(start: monday, duration: 86400 * 7)
        }
        return DateInterval(start: monday, end: weekEnd)
    }

    /// Monday (`startOfDay`) of the week containing the date.
    static func mondayOfWeek(containing date: Date) -> Date {
        let cal = weekCalendar
        if let week = cal.dateInterval(of: .weekOfYear, for: date) {
            return cal.startOfDay(for: week.start)
        }
        return cal.startOfDay(for: date)
    }

    /// Move N weeks forward/backward from the selected week (negative moves backward).
    func weekStartOffset(by weeks: Int) -> Date {
        let cal = MeetingDraft.weekCalendar
        let monday = cal.startOfDay(for: selectedWeekStart)
        return cal.date(byAdding: .day, value: 7 * weeks, to: monday) ?? monday
    }

    static var weekCalendar: Calendar {
        var cal = AppTimeZone.calendar
        cal.firstWeekday = 2 // Monday — match typical RU/EU «рабочая неделя»
        return cal
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
