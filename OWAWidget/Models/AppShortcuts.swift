import Foundation
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let createMeeting = Self("createMeeting", default: .init(.n, modifiers: [.control, .option]))
    static let joinMeeting = Self("joinMeeting", default: .init(.j, modifiers: [.control, .option]))
    static let openMail = Self("openMail", default: .init(.m, modifiers: [.control, .option]))
}

extension Notification.Name {
    static let openCreateMeetingShortcut = Notification.Name("openCreateMeetingShortcut")
    static let openMailShortcut = Notification.Name("openMailShortcut")
}
