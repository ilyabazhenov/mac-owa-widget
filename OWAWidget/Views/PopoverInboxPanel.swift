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
    /// Whether the panel found room beside the popover (`false`: the popover keeps its strips).
    let onPlacementChange: (Bool) -> Void

    func makeNSView(context: Context) -> InboxPanelAttachmentView {
        InboxPanelAttachmentView()
    }

    func updateNSView(_ view: InboxPanelAttachmentView, context: Context) {
        view.update(isEnabled: isEnabled, width: width, content: content, onShow: onShow, onPlacementChange: onPlacementChange)
    }

    static func dismantleNSView(_ view: InboxPanelAttachmentView, coordinator: ()) {
        view.detach()
    }
}

final class InboxPanelAttachmentView: NSView {
    static let gap: CGFloat = 8

    private var panel: InboxPanel?
    private var hosting: FirstMouseHostingView<AnyView>?
    /// The "glass" under the content, matched to the popover's: on it AppKit draws labels and
    /// icons vibrant (brighter), so without it the same icon looks dimmer than in the popover.
    private var backdrop: NSVisualEffectView?
    private var isEnabled = false
    private var width: CGFloat = 340
    private var onShow: () -> Void = {}
    private var onPlacementChange: (Bool) -> Void = { _ in }
    private var reportedPlacement: Bool?
    private var observers: [NSObjectProtocol] = []

    /// Called on every update of the popover's view. The content is set once: it observes the
    /// services itself, so re-rooting it on each update would only redo the whole column. The
    /// placement is redone only when something it depends on changed; the window notifications
    /// cover moves, resizes and the popover opening or closing.
    func update(isEnabled: Bool, width: CGFloat, content: AnyView, onShow: @escaping () -> Void, onPlacementChange: @escaping (Bool) -> Void) {
        self.onShow = onShow
        self.onPlacementChange = onPlacementChange
        let changed = isEnabled != self.isEnabled || width != self.width
        self.isEnabled = isEnabled
        self.width = width
        var created = false
        if hosting == nil, isEnabled {
            makePanel(content)
            created = true
        }
        if changed || created { sync() }
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
        let backdrop = NSVisualEffectView(frame: panel.contentRect(forFrameRect: panel.frame))
        backdrop.material = .popover
        backdrop.blendingMode = .behindWindow
        // Never key, so following the window state would leave it looking inactive.
        backdrop.state = .active
        // Corners are cut on the layer, so the window shadow follows them too.
        backdrop.wantsLayer = true
        backdrop.layer?.masksToBounds = true
        backdrop.layer?.cornerCurve = .continuous
        backdrop.layer?.borderWidth = 0.5
        let hosting = FirstMouseHostingView(rootView: content)
        hosting.frame = backdrop.bounds
        hosting.autoresizingMask = [.width, .height]
        backdrop.addSubview(hosting)
        panel.contentView = backdrop
        self.panel = panel
        self.hosting = hosting
        self.backdrop = backdrop
    }

    /// Shows the panel beside a visible popover, hides it otherwise.
    private func sync() {
        guard isEnabled, let window, let panel, window.isVisible, window.occlusionState.contains(.visible) else {
            hidePanel()
            return
        }
        guard let frame = Self.panelFrame(beside: window.frame, width: width, screen: window.screen?.visibleFrame) else {
            hidePanel()
            reportPlacement(false)
            return
        }
        reportPlacement(true)
        applyAppearance()
        let wasVisible = panel.isVisible
        // Already in place beside this popover: nothing to redo.
        if wasVisible, panel.parent === window, panel.frame == frame { return }
        panel.level = window.level
        let radius = Self.cornerRadius(of: window)
        if let source = Self.visualEffectView(in: window), let backdrop {
            backdrop.material = source.material
            backdrop.blendingMode = source.blendingMode
        }
        if backdrop?.layer?.cornerRadius != radius {
            backdrop?.layer?.cornerRadius = radius
            // The window server draws the behind-window blur itself and ignores the layer's
            // corners: without a mask the material shows as square corners under the rounded
            // content, and the shadow stays square too.
            backdrop?.maskImage = Self.roundedMask(radius: radius)
            DiagnosticLog.event("Inbox panel corner radius=\(radius)")
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

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
    }

    /// Gives the panel the appearance the popover's content is drawn in: this view's, not the
    /// popover window's, and again whenever it changes. Taken from the window only on placement,
    /// the panel stayed dark beside a light calendar after macOS switched to light mode on its own.
    private func applyAppearance() {
        guard let panel else { return }
        let appearance = effectiveAppearance
        panel.appearance = appearance
        appearance.performAsCurrentDrawingAppearance {
            backdrop?.layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }

    /// Tells the popover once per change, outside the view update that may have caused it.
    private func reportPlacement(_ placed: Bool) {
        guard reportedPlacement != placed else { return }
        reportedPlacement = placed
        let callback = onPlacementChange
        DispatchQueue.main.async { callback(placed) }
    }

    private func hidePanel() {
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    /// The first visual effect view in the popover window (its frame view included).
    static func visualEffectView(in window: NSWindow) -> NSVisualEffectView? {
        func find(_ view: NSView) -> NSVisualEffectView? {
            if let effect = view as? NSVisualEffectView { return effect }
            for child in view.subviews {
                if let found = find(child) { return found }
            }
            return nil
        }
        guard let root = window.contentView?.superview ?? window.contentView else { return nil }
        return find(root)
    }

    /// A stretchable rounded rectangle for `NSVisualEffectView.maskImage`: only the corners are
    /// fixed, so one image fits the panel at any height.
    static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
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
