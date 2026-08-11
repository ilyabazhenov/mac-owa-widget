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

    /// The MenuBarExtra popover window, once it has appeared. Callers use it to tell popover key
    /// events apart from events belonging to the settings or create-meeting windows.
    var registeredPopoverWindow: NSWindow? { popoverWindow }

    func dismissAfterJoin(context _: PostJoinContext) {
        dismissPopover()
    }

    /// Closes the popover regardless of why — after a join, or on Esc.
    func dismissPopover() {
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
