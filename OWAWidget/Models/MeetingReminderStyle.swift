import Foundation

/// How meeting reminders are delivered.
enum MeetingReminderStyle: String, CaseIterable, Identifiable, Sendable {
    /// macOS UserNotification banners / Notification Center.
    case system
    /// In-app floating panel (no system permission dialog for delivery).
    case inApp
    /// System + in-app.
    case both

    var id: String { rawValue }

    var usesSystemNotifications: Bool {
        switch self {
        case .system, .both: return true
        case .inApp: return false
        }
    }

    var usesInAppBanners: Bool {
        switch self {
        case .inApp, .both: return true
        case .system: return false
        }
    }

    var localizationKey: String {
        switch self {
        case .system: "preferences.notifications.style.system"
        case .inApp: "preferences.notifications.style.inApp"
        case .both: "preferences.notifications.style.both"
        }
    }
}
