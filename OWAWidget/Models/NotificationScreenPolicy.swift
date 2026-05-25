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
        let primaryIndex = Self.primaryScreenIndex(displayIDs: displayIDs, mainDisplayID: mainDisplayID)

        switch self {
        case .main:
            if let index = primaryIndex { return screens[index] }
            return screens.first
        case .active:
            if let index = Self.activeScreenIndex(frames: frames, mouseLocation: mouseLocation) {
                return screens[index]
            }
            // Курсор оказался в «щели» между мониторами или на границе — NSRect.contains
            // не включает правый/верхний край. Берём ближайший экран по расстоянию,
            // чтобы не свалиться в screens.first (порядок NSScreen.screens не гарантирован
            // между sleep/wake и переподключениями монитора — иначе уведомление
            // уезжает на «случайный» экран и визуально оказывается внизу).
            if let index = Self.nearestScreenIndex(frames: frames, mouseLocation: mouseLocation) {
                return screens[index]
            }
            if let index = primaryIndex { return screens[index] }
            return screens.first
        }
    }

    static func primaryScreenIndex(displayIDs: [CGDirectDisplayID?], mainDisplayID: CGDirectDisplayID) -> Int? {
        displayIDs.firstIndex(where: { $0 == mainDisplayID })
    }

    static func activeScreenIndex(frames: [CGRect], mouseLocation: CGPoint) -> Int? {
        frames.firstIndex(where: { $0.contains(mouseLocation) })
    }

    /// Индекс экрана с минимальным расстоянием от `mouseLocation` до его прямоугольника.
    /// Используется как fallback, если ни один frame не содержит точку (стык мониторов,
    /// зоны вне всех frames при разной высоте экранов, точка ровно на границе).
    static func nearestScreenIndex(frames: [CGRect], mouseLocation: CGPoint) -> Int? {
        guard !frames.isEmpty else { return nil }
        var bestIndex = 0
        var bestDistance = Self.distanceSquared(from: mouseLocation, to: frames[0])
        for index in frames.indices.dropFirst() {
            let distance = Self.distanceSquared(from: mouseLocation, to: frames[index])
            if distance < bestDistance {
                bestDistance = distance
                bestIndex = index
            }
        }
        return bestIndex
    }

    static func distanceSquared(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return dx * dx + dy * dy
    }

    private static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(number.uint32Value)
    }
}
