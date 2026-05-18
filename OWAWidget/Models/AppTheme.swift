import Foundation

enum AppTheme: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var localizationKey: String {
        "appearance.option.\(rawValue)"
    }
}
