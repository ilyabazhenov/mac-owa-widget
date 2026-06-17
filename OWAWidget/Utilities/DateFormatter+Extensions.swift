import Foundation

extension DateFormatter {
    // The timezone is re-applied on every access (cheap) rather than captured once at init,
    // so a change to the configurable display timezone takes effect without recreating the
    // formatter. Accessed on the main actor during rendering.
    private static let _shortTime: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    static var shortTime: DateFormatter {
        _shortTime.timeZone = AppTimeZone.zone
        return _shortTime
    }

    private static let _shortDate: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    static var shortDate: DateFormatter {
        _shortDate.timeZone = AppTimeZone.zone
        return _shortDate
    }
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
