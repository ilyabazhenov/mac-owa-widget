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
    /// 0.0–1.0; 1.0 — слот раньше в дне (9:00), 0.0 — позже (18:00).
    /// Используется как фактор ранжирования и для окраски в heat-map.
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
}

enum SlotAvailabilityState: Sendable {
    case free(score: Double)
    case tentative
    case busy
    case outOfOffice

    static func aggregate(from chars: [Character]) -> SlotAvailabilityState {
        guard let worst = chars.max() else { return .free(score: 0) }
        switch worst {
        case "3": return .outOfOffice
        case "2": return .busy
        case "1": return .tentative
        default:  return .free(score: 0)
        }
    }
}

/// Позиция строки внутри многострочного свободного слота.
enum FreeSlotPosition: Sendable {
    case single   // 30-мин слот — одна строка, скругление со всех сторон
    case start    // первая строка многострочного слота — скругление сверху
    case middle   // промежуточная строка — без скруглений
    case end      // последняя строка — скругление снизу
}

struct CellAvailability: Sendable {
    let state: SlotAvailabilityState
    let attendeeStatuses: [AttendeeSlotStatus]
    /// Non-nil → ячейка соответствует свободному слоту и кликабельна.
    let freeSlot: FreeSlot?
    var slotPosition: FreeSlotPosition = .single
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
    /// Понедельник (startOfDay) выбранной недели. Поиск слотов идёт по Mon–Fri этой недели.
    var selectedWeekStart: Date = MeetingDraft.mondayOfWeek(containing: Date())

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
    }

    /// Поиск слотов: Mon 00:00 → Fri 18:00 выбранной недели. Для **текущей** недели
    /// (`referenceNow` лежит между Mon и Fri 18:00) старт обрезается до `referenceNow`,
    /// чтобы не предлагать прошедшие слоты. После окончания пятницы — пустой интервал.
    func dateInterval(referenceNow: Date = Date()) -> DateInterval {
        let cal = MeetingDraft.weekCalendar
        let monday = cal.startOfDay(for: selectedWeekStart)
        guard let friday = cal.date(byAdding: .day, value: 4, to: monday),
              let dayEnd = cal.date(bySettingHour: 18, minute: 0, second: 0, of: friday)
        else {
            return DateInterval(start: monday, duration: 0)
        }
        // Для прошлых недель — пустой интервал (нечего искать в прошлом).
        if dayEnd <= referenceNow {
            return DateInterval(start: dayEnd, duration: 0)
        }
        // Для текущей недели — стартуем не раньше referenceNow.
        let rawStart = max(monday, referenceNow)
        let start = min(rawStart, dayEnd)
        return DateInterval(start: start, end: dayEnd)
    }

    /// Календарная неделя (Mon–Sun) выбранной даты — служит сеткой колонок Mon–Fri.
    func slotGridWeekInterval(referenceNow: Date = Date()) -> DateInterval {
        let cal = MeetingDraft.weekCalendar
        let monday = cal.startOfDay(for: selectedWeekStart)
        guard let weekEnd = cal.date(byAdding: .day, value: 7, to: monday) else {
            return DateInterval(start: monday, duration: 86400 * 7)
        }
        return DateInterval(start: monday, end: weekEnd)
    }

    /// Понедельник (startOfDay) недели, содержащей дату.
    static func mondayOfWeek(containing date: Date) -> Date {
        let cal = weekCalendar
        if let week = cal.dateInterval(of: .weekOfYear, for: date) {
            return cal.startOfDay(for: week.start)
        }
        return cal.startOfDay(for: date)
    }

    /// Сдвиг на N недель вперёд/назад от выбранной (отрицательно — назад).
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
