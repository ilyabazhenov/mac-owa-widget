import AppKit
import Foundation
import SwiftUI

/// Floating in-app meeting reminders (non–Notification Center).
@MainActor
final class CustomMeetingReminderController {
    private struct Payload: Sendable {
        let clusterID: String
        let title: String
        let subtitle: String
        let items: [MeetingReminderItem]
        let joinTitle: String
        let dismissTitle: String
        let meetingStartDate: Date
    }

    private var scheduledWork: [String: DispatchWorkItem] = [:]
    private var queue: [Payload] = []
    private var currentPanel: NSPanel?
    private var dismissWorkItem: DispatchWorkItem?
    private var currentSound: MeetingReminderSound = .default
    private let postStartGrace: TimeInterval = 5 * 60
    private let duplicateSuppressWindow: TimeInterval = 60
    private var scheduleGeneration: UInt64 = 0
    private var recentlyPresentedAt: [String: Date] = [:]
    var onJoin: ((MeetingReminderItem) -> Void)?

    func cancelAll(closeActiveReminder: Bool) {
        scheduleGeneration &+= 1
        for (_, item) in scheduledWork { item.cancel() }
        scheduledWork.removeAll()
        queue.removeAll()
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        if closeActiveReminder {
            currentPanel?.close()
            currentPanel = nil
        }
    }

    func reschedule(
        events: [CalendarEvent],
        leadMinutes: Int,
        localization: NotificationLocalization,
        sound: MeetingReminderSound
    ) {
        cancelAll(closeActiveReminder: false)
        currentSound = sound
        let generation = scheduleGeneration

        let joinTitle = localization.joinActionTitle
        let dismissTitle = localization.dismissActionTitle
        let now = Date()
        let clusters = MeetingReminderClusterBuilder.clusters(from: events, now: now)
        for cluster in clusters {
            guard let delay = MeetingReminderSchedule.deliveryDelay(
                event: cluster.anchorEvent,
                leadMinutes: leadMinutes,
                from: now
            ) else { continue }

            let subtitle = MeetingReminderText.reminderBody(cluster: cluster, leadMinutes: leadMinutes, localization: localization)
            let payload = Payload(
                clusterID: cluster.id,
                title: MeetingReminderText.title(cluster: cluster, localization: localization),
                subtitle: subtitle,
                items: cluster.items,
                joinTitle: joinTitle,
                dismissTitle: dismissTitle,
                meetingStartDate: cluster.anchorEvent.startDate
            )

            var work: DispatchWorkItem?
            work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    self.scheduledWork.removeValue(forKey: cluster.id)
                    guard generation == self.scheduleGeneration else { return }
                    guard !(work?.isCancelled ?? true) else { return }
                    self.enqueue(payload)
                }
            }
            guard let work else { continue }
            scheduledWork[cluster.id] = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    private func enqueue(_ payload: Payload) {
        evictExpiredPresentedClusters(now: Date())
        if let lastPresented = recentlyPresentedAt[payload.clusterID],
           Date().timeIntervalSince(lastPresented) < duplicateSuppressWindow {
            return
        }
        queue.append(payload)
        presentNextIfIdle()
    }

    private func presentNextIfIdle() {
        guard currentPanel == nil, let next = queue.first else { return }
        queue.removeFirst()
        present(next)
    }

    private func present(_ payload: Payload) {
        recentlyPresentedAt[payload.clusterID] = Date()
        dismissWorkItem?.cancel()
        dismissWorkItem = nil

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 200),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true

        let view = MeetingReminderBannerView(
            title: payload.title,
            subtitle: payload.subtitle,
            items: payload.items,
            accentColor: .orange,
            joinTitle: payload.joinTitle,
            dismissTitle: payload.dismissTitle,
            onJoin: { [weak self, weak panel] item in
                self?.dismissWorkItem?.cancel()
                self?.dismissWorkItem = nil
                if let onJoin = self?.onJoin {
                    onJoin(item)
                } else if let url = item.joinURL {
                    NSWorkspace.shared.open(url)
                }
                panel?.close()
                self?.finishPresentation()
            },
            onDismiss: { [weak self, weak panel] in
                self?.dismissWorkItem?.cancel()
                self?.dismissWorkItem = nil
                panel?.close()
                self?.finishPresentation()
            }
        )

        let hosting = NSHostingView(rootView: view)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView(frame: .zero)
        container.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: container.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        panel.contentView = container

        container.layoutSubtreeIfNeeded()
        let fit = hosting.fittingSize
        let size = NSSize(width: max(320, fit.width), height: max(80, fit.height))
        panel.setContentSize(size)

        positionPanel(panel, contentSize: size)

        currentPanel = panel
        panel.orderFrontRegardless()

        currentSound.play()

        let dismiss = DispatchWorkItem { [weak self, weak panel] in
            panel?.close()
            self?.finishPresentation()
        }
        dismissWorkItem = dismiss
        let autoDismissDeadline = max(payload.meetingStartDate + postStartGrace, Date() + 30)
        DispatchQueue.main.asyncAfter(deadline: .now() + autoDismissDeadline.timeIntervalSinceNow, execute: dismiss)
    }

    private func positionPanel(_ panel: NSPanel, contentSize: NSSize) {
        guard let screen = NotificationScreenPolicy.current.resolve() else { return }
        let vf = screen.visibleFrame
        let margin: CGFloat = 16
        let x = vf.maxX - contentSize.width - margin
        let y = vf.maxY - contentSize.height - margin
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func finishPresentation() {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        currentPanel = nil
        presentNextIfIdle()
    }

    private func evictExpiredPresentedClusters(now: Date) {
        recentlyPresentedAt = recentlyPresentedAt.filter { now.timeIntervalSince($0.value) < duplicateSuppressWindow }
    }
}

extension CustomMeetingReminderController: CustomMeetingReminderControlling {}
