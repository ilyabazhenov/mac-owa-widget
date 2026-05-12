import AppKit
import CoreGraphics
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
        resolve(
            screens: NSScreen.screens,
            mainDisplayID: CGMainDisplayID(),
            mouseLocation: NSEvent.mouseLocation
        )
    }

    func resolve(
        screens: [NSScreen],
        mainDisplayID: CGDirectDisplayID,
        mouseLocation: NSPoint
    ) -> NSScreen? {
        let displayIDs = screens.map { Self.displayID(for: $0) }
        let frames = screens.map(\.frame)

        switch self {
        case .main:
            guard let index = Self.primaryScreenIndex(displayIDs: displayIDs, mainDisplayID: mainDisplayID) else {
                return screens.first
            }
            return screens[index]
        case .active:
            guard let index = Self.activeScreenIndex(frames: frames, mouseLocation: mouseLocation) else {
                return screens.first
            }
            return screens[index]
        }
    }

    static func primaryScreenIndex(displayIDs: [CGDirectDisplayID?], mainDisplayID: CGDirectDisplayID) -> Int? {
        displayIDs.firstIndex(where: { $0 == mainDisplayID })
    }

    static func activeScreenIndex(frames: [CGRect], mouseLocation: CGPoint) -> Int? {
        frames.firstIndex(where: { $0.contains(mouseLocation) })
    }

    private static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(number.uint32Value)
    }
}
