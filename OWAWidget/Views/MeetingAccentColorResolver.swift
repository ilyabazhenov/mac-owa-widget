import SwiftUI

@MainActor
func meetingAccentColor(for event: CalendarEvent) -> Color {
    if let categoryColor = meetingCategoryColor(from: event.categories)?.color {
        return categoryColor
    }
    return event.platform.color
}

enum MeetingCategoryAccent: String {
    case yellow
    case orange
    case red
    case pink
    case purple
    case blue
    case green
    case gray

    var color: Color {
        switch self {
        case .yellow: .yellow
        case .orange: .orange
        case .red: .red
        case .pink: .pink
        case .purple: .purple
        case .blue: .blue
        case .green: .green
        case .gray: .gray
        }
    }
}

func meetingCategoryColor(from categories: [String]) -> MeetingCategoryAccent? {
    for category in categories {
        let normalized = category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.isEmpty { continue }

        if normalized.contains("yellow") || normalized.contains("желт") {
            return .yellow
        }
        if normalized.contains("orange") || normalized.contains("оранж") {
            return .orange
        }
        if normalized.contains("red") || normalized.contains("красн") {
            return .red
        }
        if normalized.contains("pink") || normalized.contains("розов") {
            return .pink
        }
        if normalized.contains("purple") || normalized.contains("фиолет") {
            return .purple
        }
        if normalized.contains("blue") || normalized.contains("син") || normalized.contains("голуб") {
            return .blue
        }
        if normalized.contains("green") || normalized.contains("зелен") {
            return .green
        }
        if normalized.contains("gray") || normalized.contains("grey") || normalized.contains("сер") {
            return .gray
        }
    }
    return nil
}
