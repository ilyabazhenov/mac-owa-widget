import AppKit
import SwiftUI

/// Where a two-finger swipe on a mail row goes, as on a phone: to the left it uncovers "Delete"
/// (and deletes outright when long enough), to the right it marks the conversation read or
/// unread on release.
///
/// Kept free of AppKit so the thresholds can be tested directly.
enum MailSwipePolicy {
    enum Axis: Equatable {
        case undecided
        case horizontal
        case vertical
    }

    enum Outcome: Equatable {
        /// Back in place.
        case close
        /// Stays open with the Delete button showing.
        case reveal
        case delete
        case toggleRead
    }

    /// Travel before the gesture picks a direction: a few points of jitter decide nothing.
    static let axisLockDistance: CGFloat = 6
    /// How far sideways travel must outrun vertical travel to be a swipe and not a slanted scroll.
    static let horizontalDominance: CGFloat = 1.5
    /// Width of the Delete button a short swipe to the left leaves open.
    static let revealWidth: CGFloat = 76
    /// A swipe to the right past this marks read or unread on release.
    static let toggleReadDistance: CGFloat = 64
    /// How far a swipe to the left deletes without stopping at the button: half the row, but
    /// never so little on a narrow one that an ordinary reveal deletes.
    static func deleteDistance(width: CGFloat) -> CGFloat {
        max(140, width * 0.5)
    }

    static func axis(dx: CGFloat, dy: CGFloat) -> Axis {
        let x = abs(dx)
        let y = abs(dy)
        guard max(x, y) >= axisLockDistance else { return .undecided }
        return x > y * horizontalDominance ? .horizontal : .vertical
    }

    /// The row's offset for a travel of the fingers: free where an action lies, nowhere where
    /// there is none, and resisting past the end, as a rubber band does.
    static func offset(travel: CGFloat, width: CGFloat, canDelete: Bool, canToggleRead: Bool) -> CGFloat {
        if travel < 0 {
            guard canDelete else { return 0 }
            return -resisted(-travel, beyond: max(width * 0.85, revealWidth))
        }
        guard canToggleRead else { return 0 }
        return resisted(travel, beyond: toggleReadDistance * 1.5)
    }

    /// The action a release at `offset` would take; also what the row shows as armed meanwhile.
    static func armed(offset: CGFloat, width: CGFloat) -> Outcome? {
        if offset <= -deleteDistance(width: width) { return .delete }
        if offset >= toggleReadDistance { return .toggleRead }
        return nil
    }

    static func outcome(offset: CGFloat, width: CGFloat) -> Outcome {
        if let armed = armed(offset: offset, width: width) { return armed }
        // Past half the button it stays open, as in Mail.
        return offset <= -revealWidth / 2 ? .reveal : .close
    }

    private static func resisted(_ distance: CGFloat, beyond limit: CGFloat) -> CGFloat {
        distance <= limit ? distance : limit + (distance - limit) * 0.25
    }
}

/// One row's side of a swipe: how far it is pushed and what it would do. Published so only the
/// row being swiped draws again while the fingers move.
@MainActor
final class MailSwipeRowState: ObservableObject {
    @Published fileprivate(set) var offset: CGFloat = 0
    @Published fileprivate(set) var armed: MailSwipePolicy.Outcome?
    /// The Delete button stays uncovered: a click on the row closes it instead of opening mail.
    @Published fileprivate(set) var isOpen = false

    // Refreshed on every render of the row; plain so assigning them publishes nothing.
    var canDelete = false
    var canToggleRead = false
    var onDelete: () -> Void = {}
    var onToggleRead: () -> Void = {}

    /// The row's window and width. Not its position: the frames AppKit reports for views inside
    /// a SwiftUI list do not match the rows drawn (a swipe went to the row below the pointer),
    /// so the row under the pointer comes from hover, the same signal that highlights it.
    fileprivate weak var probe: NSView?

    fileprivate var width: CGFloat { probe?.bounds.width ?? 0 }
}

/// Opaque monitor token, as in `DayPagingSwipeMonitor`: `NSEvent`'s monitor object is only ever
/// handed back to AppKit.
private struct SwipeMonitorToken: @unchecked Sendable {
    let value: Any
}

/// The swipes of one list. A two-finger swipe on macOS is not a `DragGesture`: it arrives as
/// `scrollWheel` events, which SwiftUI offers no hook for, so a local monitor watches them,
/// takes the row the pointer is over (the highlighted one) and swallows the events of a
/// sideways swipe (the list does not scroll meanwhile). Everything else passes through untouched.
@MainActor
final class MailSwipeController: ObservableObject {
    /// Refreshed on every render of the list from the mail settings.
    var isEnabled = false

    /// The row under the pointer, as its hover reports.
    private weak var hovered: MailSwipeRowState?
    private var monitors: [SwipeMonitorToken] = []

    // The gesture in progress.
    private weak var active: MailSwipeRowState?
    private var axis: MailSwipePolicy.Axis = .undecided
    private var travelX: CGFloat = 0
    private var travelY: CGFloat = 0
    private var startOffset: CGFloat = 0
    private var isTracking = false
    /// The fingers lifted after a sideways swipe: its momentum must not scroll the list.
    private var swallowsMomentum = false
    private weak var openRow: MailSwipeRowState?

    fileprivate func hover(_ row: MailSwipeRowState, inside: Bool) {
        if inside {
            hovered = row
        } else if hovered === row {
            hovered = nil
        }
    }

    func install() {
        guard monitors.isEmpty else { return }
        let scroll = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, PerfProbe.interval("swipe.scroll", { self.handleScroll(event) }) else { return event }
            return nil
        }
        // A click anywhere but on the open row closes it, and still does what it was for.
        let click = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.handleClick(event)
            return event
        }
        monitors = [scroll, click].compactMap { $0.map(SwipeMonitorToken.init(value:)) }
    }

    func remove() {
        monitors.forEach { NSEvent.removeMonitor($0.value) }
        monitors = []
        if let openRow { close(openRow, animated: false) }
    }

    /// The Delete button, or a swipe long enough: the row slides away and the list drops it.
    fileprivate func delete(_ row: MailSwipeRowState) {
        let width = max(row.width, MailSwipePolicy.revealWidth)
        withAnimation(.easeOut(duration: 0.18)) {
            row.offset = -width
            row.armed = nil
        }
        row.isOpen = false
        if openRow === row { openRow = nil }
        row.onDelete()
        // A row the list keeps (the delete failed before it left) comes back into place.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak row] in
            guard let row, row.offset != 0 else { return }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { row.offset = 0 }
        }
    }

    fileprivate func close(_ row: MailSwipeRowState, animated: Bool = true) {
        let reset = {
            row.offset = 0
            row.armed = nil
        }
        if animated { withAnimation(.spring(response: 0.3, dampingFraction: 0.85), reset) } else { reset() }
        row.isOpen = false
        if openRow === row { openRow = nil }
    }

    // MARK: - Events

    /// `true` when the event belongs to a row swipe and must not reach the list.
    private func handleScroll(_ event: NSEvent) -> Bool {
        if !event.momentumPhase.isEmpty {
            guard swallowsMomentum else { return false }
            if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) { swallowsMomentum = false }
            return true
        }
        // A classic mouse wheel has no phases: it scrolls, it never swipes.
        guard !event.phase.isEmpty else { return false }

        if event.phase.contains(.began) {
            swallowsMomentum = false
            isTracking = false
            active = nil
            guard isEnabled, let row = row(at: event) else {
                if let openRow, openRow.probe?.window === event.window { close(openRow) }
                return false
            }
            if let openRow, openRow !== row { close(openRow) }
            active = row
            axis = .undecided
            travelX = 0
            travelY = 0
            startOffset = row.offset
            isTracking = true
        }

        guard isTracking, let row = active else { return false }

        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            isTracking = false
            active = nil
            guard axis == .horizontal else { return false }
            finish(row, cancelled: event.phase.contains(.cancelled))
            swallowsMomentum = true
            return true
        }

        // The row follows the fingers whichever way the user set scrolling to go.
        let fingersX = event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
        travelX += fingersX
        travelY += event.scrollingDeltaY

        if axis == .undecided {
            axis = MailSwipePolicy.axis(dx: travelX, dy: travelY)
            switch axis {
            case .undecided:
                return false
            case .vertical:
                // A scroll of the list: an open row closes, the rest is the list's.
                if let openRow { close(openRow) }
                isTracking = false
                active = nil
                return false
            case .horizontal:
                PerfProbe.mark("swipe.begin")
            }
        }

        let offset = MailSwipePolicy.offset(
            travel: startOffset + travelX,
            width: row.width,
            canDelete: row.canDelete,
            canToggleRead: row.canToggleRead
        )
        let armed = MailSwipePolicy.armed(offset: offset, width: row.width)
        PerfProbe.mark("swipe.move")
        if armed != row.armed {
            // The tick a phone's swipe gives when letting go would act: a swipe leaves no button
            // to light up, so the trackpad says it. Silent without a Force Touch trackpad.
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            withAnimation(.easeOut(duration: 0.12)) { row.armed = armed }
        }
        row.offset = offset
        return true
    }

    private func finish(_ row: MailSwipeRowState, cancelled: Bool) {
        let outcome = cancelled ? .close : MailSwipePolicy.outcome(offset: row.offset, width: row.width)
        PerfProbe.mark("swipe.\(outcome)")
        switch outcome {
        case .delete:
            delete(row)
        case .toggleRead:
            close(row)
            row.onToggleRead()
        case .reveal:
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                row.offset = -MailSwipePolicy.revealWidth
                row.armed = nil
            }
            row.isOpen = true
            openRow = row
        case .close:
            close(row)
        }
    }

    private func handleClick(_ event: NSEvent) {
        guard let openRow, openRow.probe?.window === event.window else { return }
        // A click on the open row itself is the row's: its Delete button, or the cover that
        // closes it.
        if hovered !== openRow { close(openRow) }
    }

    /// The row the pointer is over, when that is in the event's window.
    private func row(at event: NSEvent) -> MailSwipeRowState? {
        guard let hovered, let window = event.window, hovered.probe?.window === window else { return nil }
        return hovered
    }

    /// Backstop for a list that never receives `onDisappear`; see `EscapeKeyMonitorBox.deinit`.
    deinit {
        let tokens = monitors
        guard !tokens.isEmpty else { return }
        if Thread.isMainThread {
            tokens.forEach { NSEvent.removeMonitor($0.value) }
        } else {
            DispatchQueue.main.async { tokens.forEach { NSEvent.removeMonitor($0.value) } }
        }
    }
}

/// An empty view behind the row that tells the controller its window and width. It never
/// takes a click: `hitTest` passes everything to the row above it.
private struct MailSwipeProbe: NSViewRepresentable {
    let row: MailSwipeRowState

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        row.probe = view
        return view
    }

    func updateNSView(_ view: ProbeView, context: Context) {
        row.probe = view
    }

    final class ProbeView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// A list row that can be swiped. Pass `canDelete: false` where deleting means nothing (a
/// conversation already in Deleted Items).
private struct MailSwipeRow: ViewModifier {
    let controller: MailSwipeController
    let isUnread: Bool
    let canDelete: Bool
    let onDelete: () -> Void
    let onToggleRead: () -> Void

    @StateObject private var row = MailSwipeRowState()
    @EnvironmentObject private var localization: LocalizationService

    func body(content: Content) -> some View {
        row.canDelete = canDelete
        row.canToggleRead = true
        row.onDelete = onDelete
        row.onToggleRead = onToggleRead
        return content
            // Opaque while it slides, or the action colour shows through the row.
            .background(row.offset != 0 ? Color(nsColor: .windowBackgroundColor) : .clear)
            .overlay {
                if row.isOpen {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { controller.close(row) }
                }
            }
            .offset(x: row.offset)
            .frame(maxWidth: .infinity)
            .background { actions }
            .clipped()
            .contentShape(Rectangle())
            .onHover { controller.hover(row, inside: $0) }
            .background(MailSwipeProbe(row: row))
            .accessibilityAction(named: Text(localization.tr(isUnread ? "mail.action.markRead" : "mail.action.markUnread"))) {
                onToggleRead()
            }
            .accessibilityAction(named: Text(localization.tr("mail.action.delete"))) {
                if canDelete { onDelete() }
            }
    }

    @ViewBuilder
    private var actions: some View {
        if row.offset < 0 {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                Button { controller.delete(row) } label: {
                    actionLabel(icon: "trash", key: "mail.swipe.delete")
                        // Armed, the label sticks to the row's edge, as on a phone.
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: row.armed == .delete ? .leading : .trailing)
                        .background(Color.red)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(width: -row.offset)
                .help(localization.tr("mail.action.delete"))
            }
        } else if row.offset > 0 {
            HStack(spacing: 0) {
                actionLabel(icon: isUnread ? "envelope.open" : "envelope.badge", key: isUnread ? "mail.swipe.read" : "mail.swipe.unread")
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: row.armed == .toggleRead ? .trailing : .leading)
                    .background(row.armed == .toggleRead ? Color.accentColor : Color.accentColor.opacity(0.75))
                    .frame(width: row.offset)
                Spacer(minLength: 0)
            }
        }
    }

    private func actionLabel(icon: String, key: String) -> some View {
        VStack(spacing: 3) {
            Image(systemName: icon).font(.app(.title, weight: .medium))
            Text(localization.tr(key)).font(.app(.caption, weight: .medium)).lineLimit(1)
        }
        .foregroundStyle(.white)
        .frame(width: MailSwipePolicy.revealWidth)
    }
}

extension View {
    /// Two-finger swipes on a mail row: to the left deletes, to the right marks read or unread.
    /// Without `isEnabled` on the controller the row is a plain row.
    func mailSwipeActions(
        _ controller: MailSwipeController,
        isUnread: Bool,
        canDelete: Bool = true,
        onDelete: @escaping () -> Void,
        onToggleRead: @escaping () -> Void
    ) -> some View {
        modifier(MailSwipeRow(controller: controller, isUnread: isUnread, canDelete: canDelete, onDelete: onDelete, onToggleRead: onToggleRead))
    }

    /// Installs a list's swipe monitor while the list is on screen.
    func mailSwipeList(_ controller: MailSwipeController, isEnabled: Bool) -> some View {
        controller.isEnabled = isEnabled
        return onAppear { controller.install() }
            .onDisappear { controller.remove() }
    }
}

/// The line at the bottom of a mail list after a swipe or a delete, with Undo when there is one.
struct MailListNoticeView: View {
    let notice: MailListNotice
    let onUndo: () -> Void
    let onClose: () -> Void
    @EnvironmentObject private var localization: LocalizationService

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(isFailure ? Color.orange : Color.secondary)
            Text(localization.tr(textKey))
                .font(.app(.footnote))
                .lineLimit(2)
            Spacer(minLength: 4)
            if case .deleted(let deletion, _, _) = notice, deletion.canUndo {
                Button(localization.tr("mail.undo.action"), action: onUndo)
                    .controlSize(.small)
            }
            Button(action: onClose) { Image(systemName: "xmark").font(.app(.micro, weight: .semibold)) }
                .buttonStyle(.mailIconCompact)
                .foregroundStyle(.secondary)
                .accessibilityLabel(localization.tr("mail.cancel"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var isFailure: Bool {
        if case .deleted = notice { return false }
        return true
    }

    private var icon: String {
        isFailure ? "exclamationmark.triangle" : "trash"
    }

    private var textKey: String {
        switch notice {
        case .deleted: "mail.undo.deleted"
        case .failed: "mail.swipe.failed"
        case .undoFailed: "mail.undo.failed"
        }
    }
}
