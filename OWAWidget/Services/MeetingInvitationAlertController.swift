import AppKit
import QuartzCore
import SwiftUI
import os.log

@MainActor
protocol MeetingInvitationAlertPresenting: AnyObject {
    /// Adds alerts to the panel, showing it if needed. `events` is the calendar they came from,
    /// used to decide which rows can be answered in place.
    func present(
        _ alerts: [MeetingInvitationAlert],
        events: [CalendarEvent],
        localization: MeetingInvitationLocalization,
        sound: MeetingReminderSound
    )
    /// Brings the panel in line with the calendar: drops invitations answered elsewhere or gone
    /// from the calendar, and closes the panel once nothing is left.
    func reconcile(with events: [CalendarEvent])
    func dismissAll()
}

/// Floating panel about new invitations, moved and cancelled meetings.
///
/// Unlike the meeting reminder it has no auto-dismiss: the point is that it is still there when
/// the user comes back to the Mac, without having heard any sound. It goes away when the user
/// closes it, answers or hides every row, or answers the invitations somewhere else.
///
/// Same single-panel design as `CustomMeetingReminderController`: new alerts are merged into the
/// panel on screen and its root view is replaced in place. There is no queue.
@MainActor
final class MeetingInvitationAlertController: MeetingInvitationAlertPresenting {
    static let visibleRowLimit = 4

    /// Sends an RSVP for the given event. Throws when the server did not accept it.
    var onRespond: ((String, MeetingResponseAction) async throws -> Void)?
    /// Shows the given event in the popover.
    var onOpen: ((String) -> Void)?
    /// The user hid a row: its invitations leave the badge. Closing the whole panel does not call
    /// this — the badge is what remembers the invitations once the panel is gone.
    var onHide: (([String]) -> Void)?

    private var panel: NSPanel?
    private var hostingView: InvitationFirstMouseHostingView<MeetingInvitationBannerView>?
    private var rows: [MeetingInvitationRow] = []
    private var localization: MeetingInvitationLocalization = .english
    private let log = Logger(subsystem: "com.owawidget", category: "InvitationAlert")

    func present(
        _ alerts: [MeetingInvitationAlert],
        events: [CalendarEvent],
        localization: MeetingInvitationLocalization,
        sound: MeetingReminderSound
    ) {
        self.localization = localization
        let byID = Self.index(events)
        var added = 0
        for alert in alerts {
            // A later change to the same meeting replaces the row about it: "moved" supersedes
            // "invited", "cancelled" supersedes both.
            let ids = Set(alert.eventIDs)
            rows.removeAll { !ids.isDisjoint(with: $0.alert.eventIDs) }
            rows.append(MeetingInvitationRow(
                alert: alert,
                canRespond: Self.canRespond(alert, byID: byID),
                sendingAction: nil,
                errorMessage: nil
            ))
            added += 1
        }
        guard added > 0 else { return }
        // Invitations stay on top even when a cancellation arrives later: they are the rows that
        // need an answer. The sort is stable, so arrival order holds within each kind.
        rows = rows.enumerated().sorted {
            ($0.element.alert.change.displayRank, $0.offset) < ($1.element.alert.change.displayRank, $1.offset)
        }.map(\.element)
        log.info("present added=\(added, privacy: .public) rows=\(self.rows.count, privacy: .public)")
        DiagnosticLog.event("Invitation panel present added=\(added) rows=\(rows.count)")

        if panel == nil {
            showPanel()
        } else {
            refreshPanel()
        }
        sound.play()
    }

    func reconcile(with events: [CalendarEvent]) {
        guard !rows.isEmpty else { return }
        let byID = Self.index(events)
        let now = Date()
        rows = rows.compactMap { row in
            // Leave a row alone while its answer is in flight: the optimistic update has already
            // flipped the event, and dropping the row here would swallow a failure message.
            guard row.sendingAction == nil else { return row }
            let alive = row.alert.eventIDs.contains { byID[$0] != nil }
            guard alive else { return nil }
            if row.alert.change == .invited {
                let stillPending = row.alert.eventIDs.contains { id in
                    byID[id].map { MeetingInvitationPolicy.isAwaitingResponse($0, now: now) } ?? false
                }
                guard stillPending else { return nil }
            }
            var updated = row
            updated.canRespond = Self.canRespond(row.alert, byID: byID)
            return updated
        }
        if rows.isEmpty {
            closePanel()
        } else if panel != nil {
            refreshPanel()
        }
    }

    func dismissAll() {
        rows = []
        closePanel()
    }

    // MARK: - Actions

    private func respond(_ row: MeetingInvitationRow, action: MeetingResponseAction) {
        guard let index = rows.firstIndex(where: { $0.id == row.id }),
              rows[index].sendingAction == nil,
              let onRespond
        else { return }
        rows[index].sendingAction = action
        rows[index].errorMessage = nil
        refreshPanel()

        let rowID = row.id
        let eventID = row.alert.representativeEventID
        Task { @MainActor in
            do {
                try await onRespond(eventID, action)
                rows.removeAll { $0.id == rowID }
            } catch {
                log.error("respond failed: \(error.localizedDescription, privacy: .public)")
                if let i = rows.firstIndex(where: { $0.id == rowID }) {
                    rows[i].sendingAction = nil
                    rows[i].errorMessage = localization.sendFailed
                }
            }
            if rows.isEmpty {
                closePanel()
            } else {
                refreshPanel()
            }
        }
    }

    private func open(_ row: MeetingInvitationRow) {
        onOpen?(row.alert.representativeEventID)
    }

    private func hide(_ row: MeetingInvitationRow) {
        rows.removeAll { $0.id == row.id }
        onHide?(row.alert.eventIDs)
        if rows.isEmpty {
            closePanel()
        } else {
            refreshPanel()
        }
    }

    // MARK: - Panel

    private func makeView() -> MeetingInvitationBannerView {
        let visible = Array(rows.prefix(Self.visibleRowLimit))
        return MeetingInvitationBannerView(
            title: localization.title(for: rows.map(\.alert)),
            rows: visible,
            hiddenRowCount: rows.count - visible.count,
            localization: localization,
            onRespond: { [weak self] row, action in self?.respond(row, action: action) },
            onOpen: { [weak self] row in self?.open(row) },
            onHide: { [weak self] row in self?.hide(row) },
            onClose: { [weak self] in self?.dismissAll() }
        )
    }

    private func showPanel() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 160),
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

        let hosting = InvitationFirstMouseHostingView(rootView: makeView())
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
        self.panel = panel
        self.hostingView = hosting

        // Sized and positioned before it is ordered in — see `CustomMeetingReminderController`
        // for why an off-screen start ends up on the wrong monitor.
        let size = fittingSize(of: hosting, in: container)
        panel.setContentSize(size)
        position(panel, size: size)

        panel.alphaValue = 0
        // Background menu-bar app: `orderFrontRegardless` is what gets the panel on screen, and
        // `makeKey` lets the first click land on a button instead of activating the window.
        panel.orderFrontRegardless()
        panel.makeKey()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    private func refreshPanel() {
        guard let panel, let hostingView, let container = panel.contentView else { return }
        hostingView.rootView = makeView()
        let size = fittingSize(of: hostingView, in: container)
        panel.setContentSize(size)
        position(panel, size: size)
    }

    private func closePanel() {
        panel?.close()
        panel = nil
        hostingView = nil
    }

    private func fittingSize(of hosting: NSView, in container: NSView) -> NSSize {
        container.layoutSubtreeIfNeeded()
        let fit = hosting.fittingSize
        return NSSize(width: max(360, fit.width), height: max(80, fit.height))
    }

    /// Same corner as the meeting reminder, stacked next to it when that one is on screen: two
    /// panels on top of each other would hide the older one completely.
    private func position(_ panel: NSPanel, size: NSSize) {
        guard let screen = NotificationScreenPolicy.current.resolve() else { return }
        let placement = NotificationPosition.current
        let margin: CGFloat = 16
        let gap: CGFloat = 8
        var origin = placement.origin(in: screen.visibleFrame, contentSize: size, margin: margin)

        let neighbours = NSApp.windows.filter {
            $0 !== panel && $0 is NSPanel && $0.isVisible && $0.level == .floating
        }
        for neighbour in neighbours where neighbour.frame.intersects(NSRect(origin: origin, size: size)) {
            origin.y = placement.isTop
                ? neighbour.frame.minY - size.height - gap
                : neighbour.frame.maxY + gap
        }
        panel.setFrameOrigin(origin)
    }

    // MARK: - Helpers

    private static func index(_ events: [CalendarEvent]) -> [String: CalendarEvent] {
        Dictionary(events.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private static func canRespond(_ alert: MeetingInvitationAlert, byID: [String: CalendarEvent]) -> Bool {
        guard alert.change != .cancelled, alert.occurrenceCount == 1,
              let event = byID[alert.representativeEventID]
        else { return false }
        return MeetingInvitationPolicy.isAwaitingResponse(event, now: Date())
    }
}

private final class InvitationFirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
