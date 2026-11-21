import AppKit
import SwiftUI

/// An answer to an invitation an MCP client asked for, as the user sees it before anything
/// reaches Exchange.
struct MCPMeetingResponseProposal: Equatable, Sendable {
    let action: MeetingResponseAction
    /// The whole series rather than this occurrence.
    let series: Bool
    /// The meeting repeats: the panel says which part the answer covers.
    let isRecurring: Bool
    /// The organizer gets the answer by mail.
    let sendResponse: Bool
    let title: String
    let start: Date
    let end: Date
    let location: String
    let organizer: String?
    /// The answer the meeting has now.
    let current: MeetingResponseType
    /// The note for the organizer; empty when none.
    let comment: String
    /// The MCP client that asked ("Claude Code"), empty when unknown.
    let client: String
}

extension MeetingResponseAction: Equatable {
    /// `accept`, `tentative`, `decline`: the tool's argument and the localization keys.
    var name: String {
        switch self {
        case .accept: "accept"
        case .tentative: "tentative"
        case .decline: "decline"
        }
    }

    init?(name: String) {
        switch name {
        case "accept": self = .accept
        case "tentative": self = .tentative
        case "decline": self = .decline
        default: return nil
        }
    }

    var responseType: MeetingResponseType {
        switch self {
        case .accept: .accepted
        case .tentative: .tentative
        case .decline: .declined
        }
    }
}

@MainActor
protocol MCPMeetingResponseConfirming: AnyObject {
    func confirm(_ proposal: MCPMeetingResponseProposal, timeout: TimeInterval) async -> MCPConfirmationOutcome
}

@MainActor
protocol MCPMeetingResponsePresenting: AnyObject {
    func show(
        _ proposal: MCPMeetingResponseProposal,
        deadline: Date,
        onConfirm: @escaping () -> Void,
        onReject: @escaping () -> Void
    )
    func close()
}

/// The respond_to_meeting question, over ``MCPConfirmationWaiter``: shown for every answer, as
/// the user asked — an answer goes to the organizer under the user's name.
@MainActor
final class MCPMeetingResponseConfirmationController: MCPMeetingResponseConfirming {
    private let presenter: MCPMeetingResponsePresenting
    private let waiter = MCPConfirmationWaiter(logName: "respond_to_meeting")

    init(presenter: MCPMeetingResponsePresenting? = nil) {
        self.presenter = presenter ?? MCPMeetingResponsePanel()
    }

    func confirm(_ proposal: MCPMeetingResponseProposal, timeout: TimeInterval) async -> MCPConfirmationOutcome {
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
final class MCPMeetingResponsePanel: MCPMeetingResponsePresenting {
    private var panel: NSPanel?

    func show(
        _ proposal: MCPMeetingResponseProposal,
        deadline: Date,
        onConfirm: @escaping () -> Void,
        onReject: @escaping () -> Void
    ) {
        close()
        let localization = LocalizationService()
        let view = MCPMeetingResponseConfirmationView(
            proposal: proposal,
            shownAt: Date(),
            deadline: deadline,
            localization: localization,
            onConfirm: onConfirm,
            onReject: onReject
        )
        .environment(\.locale, localization.locale)
        self.panel = MCPFloatingPanel.present(view, width: 420, firstClickActs: false)
    }

    func close() {
        panel?.close()
        panel = nil
    }
}
