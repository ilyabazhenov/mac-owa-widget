import Foundation

extension DateFormatter {
    static let shortTime: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        f.timeZone = AppTimeZone.zone
        return f
    }()

    static let shortDate: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        f.timeZone = AppTimeZone.zone
        return f
    }()
}

extension Date {
    var shortTime: String { DateFormatter.shortTime.string(from: self) }

    func timeRange(to end: Date) -> String {
        "\(shortTime)–\(end.shortTime)"
    }

    var isToday: Bool { AppTimeZone.calendar.isDateInToday(self) }
    var isTomorrow: Bool { AppTimeZone.calendar.isDateInTomorrow(self) }

    var sectionLabel: String {
        if isToday { return "Today" }
        if isTomorrow { return "Tomorrow" }
        return DateFormatter.shortDate.string(from: self)
    }
}
