import AppKit
import Foundation

enum NotificationPosition: String, CaseIterable, Identifiable, Sendable {
    case topLeft
    case topCenter
    case topRight
    case bottomLeft
    case bottomCenter
    case bottomRight

    static let defaultsKey = "notificationPosition"
    static let `default`: NotificationPosition = .topRight

    static var current: NotificationPosition {
        guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
              let position = NotificationPosition(rawValue: raw)
        else { return .default }
        return position
    }

    var id: String { rawValue }

    static let topCases: [NotificationPosition] = [.topLeft, .topCenter, .topRight]
    static let bottomCases: [NotificationPosition] = [.bottomLeft, .bottomCenter, .bottomRight]

    var isTop: Bool {
        switch self {
        case .topLeft, .topCenter, .topRight: true
        case .bottomLeft, .bottomCenter, .bottomRight: false
        }
    }

    var groupLocalizationKey: String {
        isTop
            ? "preferences.notifications.position.group.top"
            : "preferences.notifications.position.group.bottom"
    }

    var shortLocalizationKey: String {
        switch self {
        case .topLeft, .bottomLeft: "preferences.notifications.position.short.left"
        case .topCenter, .bottomCenter: "preferences.notifications.position.short.center"
        case .topRight, .bottomRight: "preferences.notifications.position.short.right"
        }
    }

    func origin(in visibleFrame: NSRect, contentSize: NSSize, margin: CGFloat) -> NSPoint {
        let x: CGFloat
        switch self {
        case .topLeft, .bottomLeft:
            x = visibleFrame.minX + margin
        case .topCenter, .bottomCenter:
            x = visibleFrame.midX - contentSize.width / 2
        case .topRight, .bottomRight:
            x = visibleFrame.maxX - contentSize.width - margin
        }
        let y: CGFloat = isTop
            ? visibleFrame.maxY - contentSize.height - margin
            : visibleFrame.minY + margin
        return NSPoint(x: x, y: y)
    }

    /// Off-screen starting origin for slide-in animation toward the target origin.
    /// For top-* — above the visible frame; for bottom-* — below it.
    func offScreenOrigin(in visibleFrame: NSRect, contentSize: NSSize, margin: CGFloat) -> NSPoint {
        let target = origin(in: visibleFrame, contentSize: contentSize, margin: margin)
        let y: CGFloat = isTop
            ? visibleFrame.maxY + margin
            : visibleFrame.minY - contentSize.height - margin
        return NSPoint(x: target.x, y: y)
    }
}
