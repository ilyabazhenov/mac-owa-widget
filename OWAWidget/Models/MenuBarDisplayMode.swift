import Foundation

enum MenuBarDisplayMode: String, CaseIterable, Identifiable {
    case countdown
    case status

    var id: String { rawValue }
}
