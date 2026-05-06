import AppKit
import SwiftUI

@MainActor
final class MeetingJoinSelectionController {
    static let shared = MeetingJoinSelectionController()

    private var panel: NSPanel?

    func present(items: [MeetingReminderItem], onJoin: @escaping (MeetingReminderItem) -> Void) {
        guard !items.isEmpty else { return }

        panel?.close()

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.title = "Choose meeting"
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false

        let view = MeetingJoinSelectionView(items: items) { [weak panel] item in
            onJoin(item)
            panel?.close()
            PostJoinDismissController.shared.dismissAfterJoin(context: .notificationPicker)
        }
        let hosting = NSHostingView(rootView: view)
        panel.contentView = hosting

        if let screen = NotificationScreenPolicy.current.resolve() {
            let visible = screen.visibleFrame
            let x = visible.maxX - panel.frame.width - 18
            let y = visible.maxY - panel.frame.height - 18
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct MeetingJoinSelectionView: View {
    let items: [MeetingReminderItem]
    let onJoin: (MeetingReminderItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Meetings starting now")
                .font(.system(size: 14, weight: .semibold))

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(items, id: \.eventID) { item in
                        HStack(spacing: 8) {
                            Image(systemName: item.platform.systemIcon)
                                .foregroundStyle(.orange)
                                .frame(width: 14)
                            Text(timeRange(item))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                                .frame(width: 90, alignment: .leading)
                            Text(item.title)
                                .font(.system(size: 12))
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            if item.hasJoinURL {
                                Button("Join") { onJoin(item) }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                            } else {
                                Text("No link")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 420, height: 260)
    }

    private func timeRange(_ item: MeetingReminderItem) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return "\(formatter.string(from: item.startDate))-\(formatter.string(from: item.endDate))"
    }
}
