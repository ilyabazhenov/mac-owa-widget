import AppKit
import Foundation

/// System sound name from `/System/Library/Sounds` for in-app meeting reminders.
enum MeetingReminderSound: String, CaseIterable, Identifiable, Sendable {
    case glass = "Glass"
    case hero = "Hero"
    case submarine = "Submarine"
    case purr = "Purr"
    case tink = "Tink"
    case ping = "Ping"
    case none = ""

    static let `default`: MeetingReminderSound = .submarine

    var id: String { rawValue }

    var localizationKey: String {
        if self == .none {
            "preferences.notifications.sound.silent"
        } else {
            "preferences.notifications.sound.\(rawValue.lowercased())"
        }
    }

    func play() {
        guard self != .none else { return }
        NSSound(named: rawValue)?.play()
    }
}
