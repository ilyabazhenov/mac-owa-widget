import AppKit
import SwiftUI

/// A meeting an MCP client asked to cancel, decline or delete, as the user sees it before
/// anything reaches Exchange.
struct MCPMeetingRemovalProposal: Equatable, Sendable {
    let mode: MeetingRemovalMode
    let title: String
    let start: Date
    let end: Date
    let location: String
    /// Who sent the invitation; shown for a decline, since they get it.
    let organizer: String?
    /// The people a cancellation goes to, without the user. Empty for the other modes.
    let attendees: [MCPMeetingProposal.Attendee]
    /// Attendees Exchange knows only by name (a distribution list, a mailbox without SMTP):
    /// they get the cancellation as well.
    let unaddressedAttendees: [String]
    /// Text for the attendees or the organizer; empty when none, always empty for a silent delete.
    let message: String
    /// One occurrence of a series: the rest of the series stays.
    let isOccurrence: Bool
    /// The organizer has already cancelled it: deleting only tidies the user's calendar.
    let isAlreadyCancelled: Bool
    /// The user has already declined it: the organizer knows, nothing more is sent.
    let isAlreadyDeclined: Bool
    /// The MCP client that asked ("Claude Code"), empty when unknown.
    let client: String
    /// The user's own mail domain is known, so `isExternal` means something.
    let externalCheckAvailable: Bool
}

@MainActor
protocol MCPMeetingRemovalConfirming: AnyObject {
    func confirm(_ proposal: MCPMeetingRemovalProposal, timeout: TimeInterval) async -> MCPConfirmationOutcome
}

@MainActor
protocol MCPMeetingRemovalPresenting: AnyObject {
    func show(
        _ proposal: MCPMeetingRemovalProposal,
        deadline: Date,
        onConfirm: @escaping () -> Void,
        onReject: @escaping () -> Void
    )
    func close()
}

/// The cancel_meeting question, over ``MCPConfirmationWaiter``. No Edit: there is nothing to
/// finish by hand.
@MainActor
final class MCPMeetingRemovalConfirmationController: MCPMeetingRemovalConfirming {
    private let presenter: MCPMeetingRemovalPresenting
    private let waiter = MCPConfirmationWaiter(logName: "cancel_meeting")

    init(presenter: MCPMeetingRemovalPresenting? = nil) {
        self.presenter = presenter ?? MCPMeetingRemovalPanel()
    }

    func confirm(_ proposal: MCPMeetingRemovalProposal, timeout: TimeInterval) async -> MCPConfirmationOutcome {
        let presenter = presenter
        return await waiter.wait(
            timeout: timeout,
            show: { deadline, answer in
                presenter.show(
                    proposal,
                    deadline: deadline,
                    onConfirm: { answer(.confirmed) },
                    onReject: { answer(.rejected) }
                )
            },
            close: { presenter.close() }
        )
    }
}

@MainActor
final class MCPMeetingRemovalPanel: MCPMeetingRemovalPresenting {
    private var panel: NSPanel?

    func show(
        _ proposal: MCPMeetingRemovalProposal,
        deadline: Date,
        onConfirm: @escaping () -> Void,
        onReject: @escaping () -> Void
    ) {
        close()
        let localization = LocalizationService()
        let view = MCPMeetingRemovalConfirmationView(
            proposal: proposal,
            shownAt: Date(),
            deadline: deadline,
            localization: localization,
            onConfirm: onConfirm,
            onReject: onReject
        )
        .environment(\.locale, localization.locale)
        // A click while the panel is not key only brings it forward: the click that refocuses it
        // must not cancel a meeting for everyone.
        self.panel = MCPFloatingPanel.present(view, width: 420, firstClickActs: false)
    }

    func close() {
        panel?.close()
        panel = nil
    }
}
