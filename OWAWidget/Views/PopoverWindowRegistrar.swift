import AppKit
import SwiftUI

extension Notification.Name {
    /// Posted each time the MenuBarExtra popover comes on screen, the first time included.
    ///
    /// SwiftUI keeps the popover's view tree alive between openings, and whether `onAppear`
    /// fires again on reopen depends on the macOS version. Views that must refresh per opening —
    /// the timeline scrolling back to the current hour — listen to this instead.
    static let owaPopoverDidOpen = Notification.Name("OWAWidget.popoverDidOpen")
}

/// Zero-size helper placed in the popover's background. It hands the popover's `NSWindow` to
/// `PostJoinDismissController` once it appears, so the popover can be dismissed after the user
/// joins a meeting, and posts `.owaPopoverDidOpen` each time that window comes on screen.
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
    /// Last seen visibility, so only a hidden → visible change counts as an opening.
    private var isWindowVisible = false

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        guard let window else { return }
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.didChangeOcclusionStateNotification,
            object: window
        )
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        PostJoinDismissController.shared.registerPopoverWindow(window)
        // MenuBarExtra orders the same window out on close and back in on reopen, which is
        // exactly what the occlusion state reports.
        isWindowVisible = window.occlusionState.contains(.visible)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowOcclusionStateDidChange(_:)),
            name: NSWindow.didChangeOcclusionStateNotification,
            object: window
        )
    }

    @objc private func windowOcclusionStateDidChange(_ notification: Notification) {
        guard let window else { return }
        let isVisible = window.occlusionState.contains(.visible)
        defer { isWindowVisible = isVisible }
        guard isVisible, !isWindowVisible else { return }
        NotificationCenter.default.post(name: .owaPopoverDidOpen, object: window)
    }
}
