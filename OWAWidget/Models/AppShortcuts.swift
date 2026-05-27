import Foundation
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let createMeeting = Self("createMeeting", default: .init(.n, modifiers: [.control, .option]))
    static let joinMeeting = Self("joinMeeting", default: .init(.j, modifiers: [.control, .option]))
}

extension Notification.Name {
    static let openCreateMeetingShortcut = Notification.Name("openCreateMeetingShortcut")
}
