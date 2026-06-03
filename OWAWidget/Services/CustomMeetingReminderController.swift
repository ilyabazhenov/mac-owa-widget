import AppKit
import Foundation
import QuartzCore
import SwiftUI
import os.log

/// Floating in-app meeting reminders (non–Notification Center).
///
/// Design invariant: at most one NSPanel is visible at any time. When a new
/// reminder fires while the panel is already showing, the panel content is
/// updated in-place (items merged, rootView replaced). This eliminates the
/// queue-based duplicate problem entirely.
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

        /// Stable suppression key: sorted event IDs, independent of item order within the cluster.
        /// Using clusterID directly would cause missed suppressions when joinURL is added between
        /// syncs (changing sort order → different clusterID for the same logical set of events).
        var suppressionKey: String {
            items.map(\.eventID).sorted().joined(separator: "|")
        }
    }

    private var scheduledWork: [String: DispatchWorkItem] = [:]
    private var currentPanel: NSPanel?
    private var currentHostingView: FirstMouseHostingView<MeetingReminderBannerView>?
    private var currentDisplayedItems: [MeetingReminderItem] = []
    private var currentAnchorStartDate: Date = .distantPast
    private var currentDismissDeadline: Date = .distantPast
    private var dismissWorkItem: DispatchWorkItem?
    private var currentSound: MeetingReminderSound = .default
    private var currentLeadMinutes: Int = 1
    private var currentLocalization: NotificationLocalization = .english
    private let postStartGrace: TimeInterval = 5 * 60
    private let duplicateSuppressWindow: TimeInterval = 60
    private var scheduleGeneration: UInt64 = 0
    private var recentlyPresentedAt: [String: Date] = [:]
    private let log = Logger(subsystem: "com.owawidget", category: "Reminder")
    var onJoin: ((MeetingReminderItem) -> Void)?

    #if DEBUG
    private static let debugLogURL = URL(fileURLWithPath: "/tmp/owawidget_reminder.log")

    init() {
        let header = "=== OWAWidget Reminder Log started \(Date()) ===\n"
        try? header.write(to: Self.debugLogURL, atomically: true, encoding: .utf8)
    }

    private func dlog(_ message: String) {
        let f = DateFormatter()
        f.timeZone = AppTimeZone.zone
        f.dateFormat = "HH:mm:ss.SSS"
        let line = "[\(f.string(from: Date()))] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: Self.debugLogURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: Self.debugLogURL, options: .atomic)
        }
    }
    #endif

    func cancelAll(closeActiveReminder: Bool) {
        scheduleGeneration &+= 1
        for (_, item) in scheduledWork { item.cancel() }
        scheduledWork.removeAll()
        if closeActiveReminder {
            dismissWorkItem?.cancel()
            dismissWorkItem = nil
            currentPanel?.close()
            currentPanel = nil
            currentHostingView = nil
            currentDisplayedItems = []
            currentAnchorStartDate = .distantPast
            currentDismissDeadline = .distantPast
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
        currentLeadMinutes = leadMinutes
        currentLocalization = localization
        let generation = scheduleGeneration

        let joinTitle = localization.joinActionTitle
        let dismissTitle = localization.dismissActionTitle
        let now = Date()
        let clusters = MeetingReminderClusterBuilder.clusters(from: events, now: now)
        log.info("reschedule gen=\(generation, privacy: .public) events=\(events.count, privacy: .public) clusters=\(clusters.count, privacy: .public)")
        #if DEBUG
        dlog("reschedule gen=\(generation) events=\(events.count) clusters=\(clusters.count) lead=\(leadMinutes)min")
        #endif
        for cluster in clusters {
            guard let delay = MeetingReminderSchedule.deliveryDelay(
                event: cluster.anchorEvent,
                leadMinutes: leadMinutes,
                from: now
            ) else {
                log.info("reschedule skip clusterID=\(cluster.id, privacy: .public) (past lead window)")
                #if DEBUG
                dlog("  skip cluster '\(cluster.anchorEvent.title)' id=\(cluster.id) (past lead window)")
                #endif
                continue
            }

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
            log.info("reschedule scheduled clusterID=\(cluster.id, privacy: .public) delay=\(delay, privacy: .public)s gen=\(generation, privacy: .public)")
            #if DEBUG
            dlog("  scheduled '\(cluster.anchorEvent.title)' delay=\(String(format: "%.1f", delay))s gen=\(generation) id=\(cluster.id)")
            #endif
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    private func enqueue(_ payload: Payload) {
        evictExpiredSuppressionEntries(now: Date())
        let suppressKey = payload.suppressionKey
        if let lastPresented = recentlyPresentedAt[suppressKey],
           Date().timeIntervalSince(lastPresented) < duplicateSuppressWindow {
            log.info("enqueue suppressed clusterID=\(payload.clusterID, privacy: .public) key=\(suppressKey, privacy: .public) lastPresentedAgo=\(Date().timeIntervalSince(lastPresented), privacy: .public)s")
            #if DEBUG
            dlog("enqueue SUPPRESSED '\(payload.title)' key=\(suppressKey) ago=\(String(format: "%.1f", Date().timeIntervalSince(lastPresented)))s")
            #endif
            return
        }
        if currentPanel == nil {
            log.info("enqueue → present clusterID=\(payload.clusterID, privacy: .public) key=\(suppressKey, privacy: .public) items=\(payload.items.count, privacy: .public)")
            #if DEBUG
            dlog("enqueue → PRESENT '\(payload.title)' key=\(suppressKey) panelIsNil=true")
            #endif
            present(payload)
        } else {
            log.info("enqueue → merge clusterID=\(payload.clusterID, privacy: .public) key=\(suppressKey, privacy: .public) items=\(payload.items.count, privacy: .public)")
            #if DEBUG
            dlog("enqueue → MERGE '\(payload.title)' key=\(suppressKey) existing=\(currentDisplayedItems.count)")
            #endif
            updateCurrentPanel(merging: payload)
        }
    }

    private func present(_ payload: Payload) {
        // Defensive: close any orphaned panel before creating a new one.
        // Under normal flow enqueue() prevents reaching here with currentPanel != nil,
        // but guard against any edge case where state becomes inconsistent.
        if let orphan = currentPanel {
            log.warning("present called with existing panel — closing orphan clusterID=\(payload.clusterID, privacy: .public)")
            #if DEBUG
            dlog("present WARNING: orphan panel found, closing before new present '\(payload.title)'")
            #endif
            orphan.close()
            finishPresentation()
        }

        log.info("present clusterID=\(payload.clusterID, privacy: .public) key=\(payload.suppressionKey, privacy: .public) items=\(payload.items.count, privacy: .public)")
        #if DEBUG
        dlog("present '\(payload.title)' key=\(payload.suppressionKey) items=\(payload.items.count) start=\(payload.meetingStartDate)")
        #endif
        recentlyPresentedAt[payload.suppressionKey] = Date()
        currentDisplayedItems = payload.items
        currentAnchorStartDate = payload.meetingStartDate
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
        panel.hidesOnDeactivate = false

        let view = MeetingReminderBannerView(
            title: payload.title,
            subtitle: payload.subtitle,
            items: payload.items,
            accentColor: .orange,
            joinTitle: payload.joinTitle,
            dismissTitle: payload.dismissTitle,
            onJoin: { [weak self, weak panel] item in
                self?.handleJoinAction(item: item, fallbackPanel: panel)
            },
            onDismiss: { [weak self, weak panel] in
                self?.closeCurrentPanelAndFinish(fallbackPanel: panel)
            }
        )

        let hosting = FirstMouseHostingView(rootView: view)
        currentHostingView = hosting
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

        // Позиционируем синхронно до orderFront. animator() на скрытом NSWindow — no-op,
        // и если до показа поставить окно в offScreenOrigin (как делает slide-in), оно
        // останется вне visibleFrame целевого экрана. macOS при появлении перетащит окно
        // на ближайший монитор, где оно ляжет у нижней границы — отсюда симптом «top-right
        // на multi-monitor оказывается снизу».
        positionPanel(panel, contentSize: size, animated: false)

        // Появление — через alpha. animator альфы корректно работает на свежепоказанном
        // окне, а позиция остаётся фиксированной.
        panel.alphaValue = 0
        currentPanel = panel
        // orderFrontRegardless ensures the panel appears even when the app is not active
        // (OWA Widget is a background menu-bar app). makeKey() then gives it key-window
        // status so SwiftUI buttons respond on first click.
        panel.orderFrontRegardless()
        panel.makeKey()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }

        currentSound.play()

        let autoDismissDeadline = max(payload.meetingStartDate + postStartGrace, Date() + 30)
        currentDismissDeadline = autoDismissDeadline
        scheduleDismissWorkItem(panel: panel, at: autoDismissDeadline)
    }

    /// Merges items from `payload` into the currently visible panel.
    /// If all items are already displayed, does nothing.
    private func updateCurrentPanel(merging payload: Payload) {
        guard let panel = currentPanel, let hosting = currentHostingView else { return }

        // 1. Merge: only add items not already displayed
        let existingIDs = Set(currentDisplayedItems.map(\.eventID))
        let newItems = payload.items.filter { !existingIDs.contains($0.eventID) }
        guard !newItems.isEmpty else { return }
        currentDisplayedItems += newItems

        // 2. Re-sort: joinURL first, then startDate, then eventID
        currentDisplayedItems.sort {
            let lRank = $0.joinURL == nil ? 1 : 0
            let rRank = $1.joinURL == nil ? 1 : 0
            if lRank != rRank { return lRank < rRank }
            if $0.startDate != $1.startDate { return $0.startDate < $1.startDate }
            return $0.eventID < $1.eventID
        }

        // 3. Keep anchor at the earliest start
        if payload.meetingStartDate < currentAnchorStartDate {
            currentAnchorStartDate = payload.meetingStartDate
        }

        // 4. Recompute title / subtitle for the merged set
        let title = MeetingReminderText.title(items: currentDisplayedItems, localization: currentLocalization)
        let subtitle = MeetingReminderText.reminderBody(
            items: currentDisplayedItems,
            anchorStartDate: currentAnchorStartDate,
            leadMinutes: currentLeadMinutes,
            localization: currentLocalization
        )

        // 5. Replace rootView — SwiftUI diffs and re-renders in place
        hosting.rootView = MeetingReminderBannerView(
            title: title,
            subtitle: subtitle,
            items: currentDisplayedItems,
            accentColor: .orange,
            joinTitle: currentLocalization.joinActionTitle,
            dismissTitle: currentLocalization.dismissActionTitle,
            onJoin: { [weak self, weak panel] item in
                self?.handleJoinAction(item: item, fallbackPanel: panel)
            },
            onDismiss: { [weak self, weak panel] in
                self?.closeCurrentPanelAndFinish(fallbackPanel: panel)
            }
        )

        // 6. Resize panel to fit updated content
        panel.contentView?.layoutSubtreeIfNeeded()
        let fit = hosting.fittingSize
        let size = NSSize(width: max(320, fit.width), height: max(80, fit.height))
        panel.setContentSize(size)
        positionPanel(panel, contentSize: size, animated: false)

        // 7. Extend auto-dismiss to cover the latest meeting in the merged set
        let latestStart = currentDisplayedItems.map(\.startDate).max() ?? currentAnchorStartDate
        let newDeadline = max(latestStart + postStartGrace, Date() + 30)
        if newDeadline > currentDismissDeadline {
            currentDismissDeadline = newDeadline
            dismissWorkItem?.cancel()
            scheduleDismissWorkItem(panel: panel, at: newDeadline)
        }
    }

    private func scheduleDismissWorkItem(panel: NSPanel, at deadline: Date) {
        let dismiss = DispatchWorkItem { [weak self, weak panel] in
            panel?.close()
            self?.finishPresentation()
        }
        dismissWorkItem = dismiss
        DispatchQueue.main.asyncAfter(deadline: .now() + deadline.timeIntervalSinceNow, execute: dismiss)
    }

    private func positionPanel(_ panel: NSPanel, contentSize: NSSize, animated: Bool) {
        guard let screen = NotificationScreenPolicy.current.resolve() else { return }
        let vf = screen.visibleFrame
        let margin: CGFloat = 16
        let position = NotificationPosition.current
        let target = position.origin(in: vf, contentSize: contentSize, margin: margin)

        // animator() на скрытом NSWindow — no-op: setFrameOrigin(start) применится, а
        // последующее panel.animator().setFrameOrigin(target) проигнорируется. Окно
        // останется в offScreenOrigin вне visibleFrame, и при orderFront macOS притянет
        // его к соседнему монитору с приземлением у нижней границы. Поэтому slide-in
        // допускаем только для уже видимого окна.
        guard animated && panel.isVisible else {
            panel.setFrameOrigin(target)
            return
        }

        let start = position.offScreenOrigin(in: vf, contentSize: contentSize, margin: margin)
        panel.setFrameOrigin(start)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ctx.allowsImplicitAnimation = true
            panel.animator().setFrameOrigin(target)
        }
    }

    private func finishPresentation() {
        log.info("finishPresentation items=\(self.currentDisplayedItems.count, privacy: .public)")
        #if DEBUG
        dlog("finishPresentation panel cleared items=\(currentDisplayedItems.count)")
        #endif
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        currentPanel = nil
        currentHostingView = nil
        currentDisplayedItems = []
        currentAnchorStartDate = .distantPast
        currentDismissDeadline = .distantPast
    }

    func handleJoinAction(item: MeetingReminderItem, fallbackPanel: NSPanel?) {
        #if DEBUG
        dlog("handleJoinAction '\(item.title)' hasURL=\(item.joinURL != nil) currentPanel=\(currentPanel != nil)")
        #endif
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        if let onJoin {
            onJoin(item)
        } else if let url = item.joinURL {
            MeetingURLOpener.open(url)
        }
        closeCurrentPanelAndFinish(fallbackPanel: fallbackPanel)
    }

    private func closeCurrentPanelAndFinish(fallbackPanel: NSPanel?) {
        #if DEBUG
        dlog("closeCurrentPanelAndFinish currentPanel=\(currentPanel != nil) fallbackPanel=\(fallbackPanel != nil)")
        #endif
        dismissWorkItem?.cancel()
        dismissWorkItem = nil

        if let panel = currentPanel {
            panel.close()
        } else {
            fallbackPanel?.close()
        }

        finishPresentation()
    }

    private func evictExpiredSuppressionEntries(now: Date) {
        recentlyPresentedAt = recentlyPresentedAt.filter { now.timeIntervalSince($0.value) < duplicateSuppressWindow }
    }
}

extension CustomMeetingReminderController: CustomMeetingReminderControlling {}

private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
