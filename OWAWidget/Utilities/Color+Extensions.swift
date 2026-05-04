import SwiftUI

extension Color {
    static let meetingNow = Color.orange
    static let meetingSoon = Color.accentColor
    static let meetingPast = Color.secondary

    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let scanner = Scanner(string: hex)
        var rgb: UInt64 = 0
        scanner.scanHexInt64(&rgb)
        let r = Double((rgb >> 16) & 0xFF) / 255
        let g = Double((rgb >> 8) & 0xFF) / 255
        let b = Double(rgb & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

extension MeetingPlatform {
    var color: Color { Color(hex: accentColorHex) }
}
