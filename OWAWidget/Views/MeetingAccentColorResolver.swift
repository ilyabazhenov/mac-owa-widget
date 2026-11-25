import SwiftUI

/// The meeting's colour: that of its category as Outlook shows it, else its call platform's.
@MainActor
func meetingAccentColor(for event: CalendarEvent) -> Color {
    if let preset = event.categoryColorPreset {
        return OutlookCategoryColor.color(preset: preset)
    }
    return event.platform.color
}

extension OutlookCategoryColor {
    /// An accent for a preset. Outlook's own swatches are pastel and vanish as a stripe on a light
    /// background, so the main hues are the system colours the widget always used and the rest
    /// are deeper versions of Outlook's.
    static func color(preset: Int) -> Color {
        switch preset {
        case red: .red
        case orange: .orange
        case brown: .brown
        case yellow: .yellow
        case green: .green
        case teal: .teal
        case olive: Color(hex: "#8A9A3B")
        case blue: .blue
        case purple: .purple
        case cranberry: .pink
        case steel: Color(hex: "#8E9AAF")
        case darkSteel: Color(hex: "#5A6A85")
        case gray: .gray
        case darkGray: Color(hex: "#5F6368")
        // Black would disappear on a dark background.
        case black: .primary
        case 15: Color(hex: "#B3261E")
        case 16: Color(hex: "#C75000")
        case 17: Color(hex: "#7A5230")
        case 18: Color(hex: "#A88B00")
        case 19: Color(hex: "#2E7D32")
        case 20: Color(hex: "#00796B")
        case 21: Color(hex: "#5F6B2A")
        case 22: Color(hex: "#1F4E9E")
        case 23: Color(hex: "#5B3A9E")
        case 24: Color(hex: "#8E2450")
        default: .gray
        }
    }
}
