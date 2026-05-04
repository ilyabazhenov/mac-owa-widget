import Foundation

extension DateFormatter {
    static let shortTime: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    static let shortDate: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()
}

extension Date {
    var shortTime: String { DateFormatter.shortTime.string(from: self) }

    func timeRange(to end: Date) -> String {
        "\(shortTime)–\(end.shortTime)"
    }

    var isToday: Bool { Calendar.current.isDateInToday(self) }
    var isTomorrow: Bool { Calendar.current.isDateInTomorrow(self) }

    var sectionLabel: String {
        if isToday { return "Today" }
        if isTomorrow { return "Tomorrow" }
        return DateFormatter.shortDate.string(from: self)
    }
}
