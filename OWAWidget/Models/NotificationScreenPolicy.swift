import AppKit
import Foundation

enum NotificationScreenPolicy: String, CaseIterable, Identifiable, Sendable {
    case main
    case active

    static let defaultsKey = "notificationScreenPolicy"

    static var current: NotificationScreenPolicy {
        guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
              let policy = NotificationScreenPolicy(rawValue: raw)
        else { return .active }
        return policy
    }

    var id: String { rawValue }

    var localizationKey: String {
        switch self {
        case .main: "preferences.notifications.screen.main"
        case .active: "preferences.notifications.screen.active"
        }
    }

    func resolve() -> NSScreen? {
        switch self {
        case .main:
            return NSScreen.main
        case .active:
            let mouseLocation = NSEvent.mouseLocation
            return NSScreen.screens.first { $0.frame.contains(mouseLocation) } ?? NSScreen.main
        }
    }
}
