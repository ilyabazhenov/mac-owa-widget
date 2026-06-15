import AppKit
import SwiftUI

/// Zero-size helper placed in the popover's background. Its only job is to hand the
/// popover's `NSWindow` to `PostJoinDismissController` once it appears, so the popover
/// can be dismissed after the user joins a meeting.
///
/// It deliberately does NOT reposition the window: MenuBarExtra owns the popover's
/// placement and overrides any `setFrame` we attempt (especially on reopen and for
/// wide popovers near the screen edge). Popover sizes are instead chosen to fit beside
/// the menu-bar icon (see `PopoverSize.Preset`), so macOS keeps it anchored on its own.
struct PopoverWindowRegistrar: NSViewRepresentable {
    func makeNSView(context: Context) -> PopoverWindowRegistrationView {
        PopoverWindowRegistrationView()
    }

    func updateNSView(_ nsView: PopoverWindowRegistrationView, context: Context) {}
}

final class PopoverWindowRegistrationView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        PostJoinDismissController.shared.registerPopoverWindow(window)
    }
}
