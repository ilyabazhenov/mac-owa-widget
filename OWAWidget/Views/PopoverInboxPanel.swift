import AppKit
import SwiftUI

/// Shows the inbox column in a panel glued to the popover's left edge.
///
/// One wider popover window does not work: beside a menu-bar icon near the right edge of the
/// screen, MenuBarExtra flips any window that does not fit to the right of the icon, and the
/// whole popover — calendar included — jumps towards the middle of the screen. A separate panel
/// leaves the popover exactly where and as wide as it always was.
///
/// The panel never becomes key: MenuBarExtra closes its window once that window loses key status,
/// so a click in a panel that took focus would close the popover it belongs to.
struct PopoverInboxPanelAttachment: NSViewRepresentable {
    let isEnabled: Bool
    let width: CGFloat
    let content: AnyView
    /// Called each time the panel comes on screen with the popover.
    let onShow: () -> Void

    func makeNSView(context: Context) -> InboxPanelAttachmentView {
        InboxPanelAttachmentView()
    }

    func updateNSView(_ view: InboxPanelAttachmentView, context: Context) {
        view.update(isEnabled: isEnabled, width: width, content: content, onShow: onShow)
    }

    static func dismantleNSView(_ view: InboxPanelAttachmentView, coordinator: ()) {
        view.detach()
    }
}

final class InboxPanelAttachmentView: NSView {
    static let gap: CGFloat = 8

    private var panel: InboxPanel?
    private var hosting: FirstMouseHostingView<AnyView>?
    private var isEnabled = false
    private var width: CGFloat = 340
    private var onShow: () -> Void = {}
    private var observers: [NSObjectProtocol] = []

    func update(isEnabled: Bool, width: CGFloat, content: AnyView, onShow: @escaping () -> Void) {
        self.isEnabled = isEnabled
        self.width = width
        self.onShow = onShow
        if let hosting {
            hosting.rootView = content
        } else if isEnabled {
            makePanel(content)
        }
        sync()
    }

    func detach() {
        hidePanel()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        panel?.close()
        panel = nil
        hosting = nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        guard let window else {
            hidePanel()
            return
        }
        let names: [Notification.Name] = [
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didMoveNotification,
            NSWindow.didResizeNotification,
            NSWindow.willCloseNotification,
        ]
        for name in names {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.sync() }
            })
        }
        sync()
    }

    private func makePanel(_ content: AnyView) {
        let panel = InboxPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 400),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        let hosting = FirstMouseHostingView(rootView: content)
        hosting.frame = panel.contentRect(forFrameRect: panel.frame)
        hosting.autoresizingMask = [.width, .height]
        // Corners are cut on the layer, so the window shadow follows them too.
        hosting.wantsLayer = true
        hosting.layer?.masksToBounds = true
        hosting.layer?.cornerCurve = .continuous
        hosting.layer?.borderWidth = 0.5
        panel.contentView = hosting
        self.panel = panel
        self.hosting = hosting
    }

    /// Shows the panel beside a visible popover, hides it otherwise.
    private func sync() {
        guard isEnabled, let window, let panel, window.isVisible, window.occlusionState.contains(.visible),
              let frame = Self.panelFrame(beside: window.frame, width: width, screen: window.screen?.visibleFrame) else {
            hidePanel()
            return
        }
        let wasVisible = panel.isVisible
        panel.appearance = window.effectiveAppearance
        panel.level = window.level
        let radius = Self.cornerRadius(of: window)
        if hosting?.layer?.cornerRadius != radius {
            hosting?.layer?.cornerRadius = radius
            DiagnosticLog.event("Inbox panel corner radius=\(radius)")
        }
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            hosting?.layer?.borderColor = NSColor.separatorColor.cgColor
        }
        panel.setFrame(frame, display: true)
        panel.invalidateShadow()
        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
        if !wasVisible { onShow() }
    }

    private func hidePanel() {
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    /// The popover window's own corner radius, so both windows round alike on every macOS
    /// (the system does not publish it; 18 pt is what macOS 26 draws for the menu-bar window).
    static func cornerRadius(of window: NSWindow) -> CGFloat {
        let key = "_cornerRadius"
        if window.responds(to: NSSelectorFromString(key)), let value = window.value(forKey: key) as? CGFloat, value > 0, value < 40 {
            return value
        }
        return 18
    }

    /// Left of the popover; on the right when the screen has no room on the left; nowhere when
    /// it has room on neither side.
    static func panelFrame(beside popover: NSRect, width: CGFloat, screen: NSRect?) -> NSRect? {
        let left = NSRect(x: popover.minX - gap - width, y: popover.minY, width: width, height: popover.height)
        guard let screen else { return left }
        if left.minX >= screen.minX { return left }
        let right = NSRect(x: popover.maxX + gap, y: popover.minY, width: width, height: popover.height)
        if right.maxX <= screen.maxX { return right }
        return nil
    }
}

/// Never key, never main: the popover keeps focus, so a click here does not close it.
final class InboxPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
