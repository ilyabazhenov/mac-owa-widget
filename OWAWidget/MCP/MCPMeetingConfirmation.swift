import AppKit
import SwiftUI

/// A meeting an MCP client asked to create, as the user sees it before anything is sent.
struct MCPMeetingProposal: Equatable, Sendable {
    struct Attendee: Equatable, Sendable {
        let email: String
        let name: String?
        /// Outside the user's own mail domain. Always `false` when `externalCheckAvailable` is
        /// `false`: the panel then says the check could not be made.
        let isExternal: Bool
    }

    struct Conflict: Equatable, Sendable {
        let title: String
        let start: Date
        let end: Date
    }

    let title: String
    let start: Date
    let end: Date
    let required: [Attendee]
    let optional: [Attendee]
    let location: String
    let agenda: String
    let conflicts: [Conflict]
    /// The MCP client that asked ("Claude Code"), empty when unknown.
    let client: String
    /// The user's own mail domain is known, so `isExternal` means something.
    let externalCheckAvailable: Bool
}

enum MCPConfirmationOutcome: Equatable, Sendable {
    case confirmed
    case rejected
    /// The user pressed Edit: the meeting goes to the New Meeting window to finish by hand.
    case handedOff
    case timedOut
    /// The client cancelled the request (`notifications/cancelled`) or disconnected.
    case cancelled
}

/// Asks the user, in OWA Widget's own window, whether to go ahead. The answer never comes from
/// the MCP client: a model can be talked into anything by a meeting description it has read.
@MainActor
protocol MCPMeetingConfirming: AnyObject {
    func confirm(_ proposal: MCPMeetingProposal, timeout: TimeInterval) async -> MCPConfirmationOutcome
}

/// Puts the question on screen. Split from the waiting logic so that can be tested without a
/// window.
@MainActor
protocol MCPConfirmationPresenting: AnyObject {
    func show(
        _ proposal: MCPMeetingProposal,
        deadline: Date,
        onConfirm: @escaping () -> Void,
        onReject: @escaping () -> Void,
        onEdit: @escaping () -> Void
    )
    func close()
}

/// Waits for exactly one answer per question: a button, the timeout or the client's cancellation,
/// whichever comes first. One question at a time; a new one replaces the old, which counts as
/// cancelled. Shared by every MCP confirmation panel (create_meeting, cancel_meeting,
/// prepare_mail), which differ only in what they show.
@MainActor
final class MCPConfirmationWaiter {
    private let logName: String
    private var pending: CheckedContinuation<MCPConfirmationOutcome, Never>?
    private var closePanel: (() -> Void)?
    private var timeoutTask: Task<Void, Never>?
    /// Which question the buttons belong to: a click that lands on a panel already answered or
    /// replaced must not answer the next one.
    private var generation = 0

    init(logName: String) {
        self.logName = logName
    }

    /// - Parameters:
    ///   - show: puts the question on screen with its deadline; the panel calls `answer` from
    ///     its buttons.
    ///   - close: takes the panel away once any answer has come.
    func wait(
        timeout: TimeInterval,
        show: @escaping (_ deadline: Date, _ answer: @escaping (MCPConfirmationOutcome) -> Void) -> Void,
        close: @escaping () -> Void
    ) async -> MCPConfirmationOutcome {
        finish(.cancelled)
        generation += 1
        let current = generation
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: .cancelled)
                    return
                }
                pending = continuation
                closePanel = close
                show(Date().addingTimeInterval(timeout)) { [weak self] outcome in
                    self?.finish(outcome, generation: current)
                }
                timeoutTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(timeout))
                    guard !Task.isCancelled else { return }
                    self?.finish(.timedOut, generation: current)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(.cancelled, generation: current) }
        }
    }

    private func finish(_ outcome: MCPConfirmationOutcome, generation answered: Int? = nil) {
        if let answered, answered != generation { return }
        guard let continuation = pending else { return }
        pending = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        closePanel?()
        closePanel = nil
        continuation.resume(returning: outcome)
        MCPDebugLog.log("\(logName) confirmation: \(outcome)")
    }
}

/// The create_meeting question, over ``MCPConfirmationWaiter``.
@MainActor
final class MCPMeetingConfirmationController: MCPMeetingConfirming {
    private let presenter: MCPConfirmationPresenting
    private let waiter = MCPConfirmationWaiter(logName: "create_meeting")

    init(presenter: MCPConfirmationPresenting? = nil) {
        self.presenter = presenter ?? MCPConfirmationPanel()
    }

    func confirm(_ proposal: MCPMeetingProposal, timeout: TimeInterval) async -> MCPConfirmationOutcome {
        let presenter = presenter
        return await waiter.wait(
            timeout: timeout,
            show: { deadline, answer in
                presenter.show(
                    proposal,
                    deadline: deadline,
                    onConfirm: { answer(.confirmed) },
                    onReject: { answer(.rejected) },
                    onEdit: { answer(.handedOff) }
                )
            },
            close: { presenter.close() }
        )
    }
}

/// The floating panel in the middle of the screen.
@MainActor
final class MCPConfirmationPanel: MCPConfirmationPresenting {
    private var panel: NSPanel?

    func show(
        _ proposal: MCPMeetingProposal,
        deadline: Date,
        onConfirm: @escaping () -> Void,
        onReject: @escaping () -> Void,
        onEdit: @escaping () -> Void
    ) {
        close()
        let localization = LocalizationService()
        let view = MCPMeetingConfirmationView(
            proposal: proposal,
            shownAt: Date(),
            deadline: deadline,
            localization: localization,
            onConfirm: onConfirm,
            onReject: onReject,
            onEdit: onEdit
        )
        .environment(\.locale, localization.locale)
        self.panel = MCPFloatingPanel.present(view, width: 420)
    }

    func close() {
        panel?.close()
        panel = nil
    }
}

/// The borderless floating panel both MCP questions use: the meeting confirmation and the new
/// client question. Centred, above other windows, key without activating the app.
@MainActor
enum MCPFloatingPanel {
    /// `hiddenFromScreenSharing` keeps the panel out of screen recordings and shared screens.
    /// `firstClickActs: false` makes a click on the panel while it is not key only bring it
    /// forward, so a user coming back to the screen cannot press a button by accident.
    static func present<Content: View>(_ view: Content, width: CGFloat, hiddenFromScreenSharing: Bool = false, firstClickActs: Bool = true) -> NSPanel {
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 240),
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
        if hiddenFromScreenSharing {
            panel.sharingType = .none
        }

        let hosting = ConfirmationFirstMouseHostingView(rootView: view)
        hosting.firstClickActs = firstClickActs
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        let fitting = hosting.fittingSize
        panel.setContentSize(NSSize(width: max(width, fitting.width), height: max(160, fitting.height)))

        // Centre of the screen, like the join picker: this one is waiting for a decision.
        if let screen = NotificationScreenPolicy.current.resolve() {
            let visible = screen.visibleFrame
            let frame = panel.frame
            panel.setFrameOrigin(NSPoint(x: visible.midX - frame.width / 2, y: visible.midY - frame.height / 2))
        }
        panel.orderFrontRegardless()
        // Key without activating the app, so Esc reaches the Cancel button.
        panel.makeKey()
        return panel
    }
}

/// Whose window this is. Both MCP panels float over other apps without a title bar, and a
/// question about calendar access that names no app is exactly the kind not to trust.
struct MCPPanelBrandBar<Trailing: View>: View {
    let localization: LocalizationService
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 6) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 16, height: 16)
            Text(localization.tr("mcp.panel.brand"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            trailing()
        }
    }
}

/// A borderless window cannot become key by default, and without that Esc goes to whatever app
/// was in front instead of the panel's Cancel button.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private final class ConfirmationFirstMouseHostingView<Content: View>: NSHostingView<Content> {
    var firstClickActs = true
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { firstClickActs }
}
