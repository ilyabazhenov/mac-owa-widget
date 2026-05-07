import Foundation

/// How meeting reminders are delivered.
enum MeetingReminderStyle: String, CaseIterable, Identifiable, Sendable {
    /// In-app floating panel (no system permission dialog for delivery).
    case inApp

    var id: String { rawValue }

    var localizationKey: String {
        switch self {
        case .inApp: "preferences.notifications.style.inApp"
        }
    }
}
