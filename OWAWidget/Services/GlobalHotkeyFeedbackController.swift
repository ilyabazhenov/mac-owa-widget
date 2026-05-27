import AppKit
import SwiftUI

@MainActor
final class GlobalHotkeyFeedbackController {
    static let shared = GlobalHotkeyFeedbackController()

    private var panel: NSPanel?
    private var dismissWorkItem: DispatchWorkItem?

    func showNoMeetingPanel(message: String, dismissAfter seconds: TimeInterval = 2.0) {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil

        panel?.close()

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 72),
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
        panel.hasShadow = true

        let view = GlobalHotkeyFeedbackView(message: message)
        let hosting = NSHostingView(rootView: view)
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = hosting

        if let screen = NotificationScreenPolicy.current.resolve() {
            let visible = screen.visibleFrame
            let x = visible.maxX - panel.frame.width - 18
            let y = visible.maxY - panel.frame.height - 18
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        self.panel = panel
        panel.orderFrontRegardless()

        let item = DispatchWorkItem { [weak panel] in
            panel?.close()
        }
        dismissWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }
}

private struct GlobalHotkeyFeedbackView: View {
    let message: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.orange)

            Text(message)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color(nsColor: .labelColor))
                .lineLimit(2)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 1)
                )
        )
    }
}

