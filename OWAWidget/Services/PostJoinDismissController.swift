import AppKit
import Foundation

@MainActor
enum PostJoinContext {
    case popoverContent
    case detailPanel
    case inAppReminder
    case notificationAction
    case notificationPicker
}

@MainActor
final class PostJoinDismissController {
    static let shared = PostJoinDismissController()

    private weak var popoverWindow: NSWindow?

    private init() {}

    func registerPopoverWindow(_ window: NSWindow) {
        popoverWindow = window
    }

    func dismissAfterJoin(context _: PostJoinContext) {
        // Primary target is MenuBarExtra popover window.
        if let popoverWindow, popoverWindow.isVisible {
            popoverWindow.close()
            return
        }

        // Fallback for edge cases when popover reference is stale.
        if let keyWindow = NSApp.keyWindow,
           keyWindow.isVisible,
           keyWindow.styleMask.contains(.nonactivatingPanel) || keyWindow.level == .statusBar {
            keyWindow.close()
        }
    }
}
