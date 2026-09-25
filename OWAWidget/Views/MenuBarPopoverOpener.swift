import AppKit

/// Opens the `MenuBarExtra` popover from code.
///
/// SwiftUI offers no API for it, so this clicks the status item's own button — the same path a
/// real click takes, which keeps the popover anchored under the icon. A popover that is already
/// open is left as it is: clicking again would close it.
@MainActor
enum MenuBarPopoverOpener {
    static func open() {
        if let popover = PostJoinDismissController.shared.registeredPopoverWindow, popover.isVisible {
            popover.makeKey()
            return
        }
        for window in NSApp.windows where window.className.contains("NSStatusBarWindow") {
            guard let button = statusButton(in: window.contentView) else { continue }
            NSApp.activate(ignoringOtherApps: true)
            button.performClick(nil)
            return
        }
        DiagnosticLog.event("MenuBarPopoverOpener: status item button not found")
    }

    private static func statusButton(in view: NSView?) -> NSButton? {
        guard let view else { return nil }
        if let button = view as? NSButton { return button }
        for subview in view.subviews {
            if let button = statusButton(in: subview) { return button }
        }
        return nil
    }
}
