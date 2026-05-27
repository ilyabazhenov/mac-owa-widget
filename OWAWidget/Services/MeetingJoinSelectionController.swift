import AppKit
import SwiftUI

@MainActor
final class MeetingJoinSelectionController {
    static let shared = MeetingJoinSelectionController()

    private var panel: NSPanel?

    func present(
        items: [MeetingReminderItem],
        localization: LocalizationService? = nil,
        onJoin: @escaping (MeetingReminderItem) -> Void
    ) {
        guard !items.isEmpty else { return }

        let localization = localization ?? LocalizationService()

        panel?.close()

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 120),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false

        let closePanel: () -> Void = { [weak panel] in
            if let panel { panel.close() }
        }

        let view = MeetingReminderBannerView(
            title: localization.tr("join.selection.title"),
            subtitle: localization.tr("join.selection.header"),
            items: items,
            accentColor: .orange,
            joinTitle: localization.tr("meeting.join"),
            dismissTitle: localization.tr("notification.action.dismiss"),
            onJoin: { item in
                onJoin(item)
                closePanel()
                PostJoinDismissController.shared.dismissAfterJoin(context: .notificationPicker)
            },
            onDismiss: closePanel
        )
        .environment(\.locale, localization.locale)

        let hosting = NSHostingView(rootView: view)
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = hosting

        hosting.layoutSubtreeIfNeeded()
        let fitting = hosting.fittingSize
        panel.setContentSize(
            NSSize(
                width: max(340, fitting.width),
                height: max(80, fitting.height)
            )
        )

        if let screen = NotificationScreenPolicy.current.resolve() {
            let visible = screen.visibleFrame
            let frame = panel.frame
            let x = visible.midX - frame.width / 2
            let y = visible.midY - frame.height / 2
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        self.panel = panel
        panel.orderFrontRegardless()
        panel.makeKey()
        NSApp.activate(ignoringOtherApps: true)
    }
}
