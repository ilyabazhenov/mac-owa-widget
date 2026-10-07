import AppKit
import SwiftUI

/// A new client asking for the calendar, as the user sees it in the question panel.
struct MCPClientApprovalRequest: Equatable, Sendable {
    let key: String
    let name: String
    let executablePath: String
    let script: String?
    let kind: MCPPeerKind
    /// The client's own name for itself, shown only when it differs from `name`.
    let declaredName: String?
    /// Creating meetings is switched on: the panel says so, since that is what the client gets too.
    let canCreateMeetings: Bool
}

enum MCPClientApprovalOutcome: Equatable, Sendable {
    case allowed
    case denied
    /// Nobody answered in time. The client stays undecided.
    case timedOut
    /// The waiting tool call was cancelled; the question itself may still be on screen.
    case cancelled
}

@MainActor
protocol MCPClientApprovalPresenting: AnyObject {
    func show(_ request: MCPClientApprovalRequest, deadline: Date, onAllow: @escaping () -> Void, onDeny: @escaping () -> Void)
    func close()
}

/// Asks "allow this client?" in OWA Widget's own window and hands the answer to every tool call
/// waiting for it.
///
/// - One question per client key: further calls from the same client wait on the question already
///   asked instead of stacking panels.
/// - One panel at a time: a second new client waits in line and gets its own full countdown.
/// - The question outlives the calls that raised it. A client that gave up (its own timeout, a
///   cancelled request, `claude -p` that exited) still gets the answer recorded through
///   `onDecision`, so it does not ask again on its next run.
/// - Each waiter gives up after `waitLimit` even when the question is still queued: an MCP client
///   cancels a request after 60 seconds, and an error it can read beats a cancellation.
@MainActor
final class MCPClientApprovalController {
    /// How long a question stays on screen. Under the 60 seconds a TypeScript SDK client waits.
    static let questionTimeout: TimeInterval = 45
    static let waitLimit: TimeInterval = 50

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<MCPClientApprovalOutcome, Never>
        let timeout: Task<Void, Never>
    }

    private struct Question {
        var request: MCPClientApprovalRequest
        var waiters: [Waiter] = []
    }

    private let presenter: MCPClientApprovalPresenting
    private let questionTimeout: TimeInterval
    private let waitLimit: TimeInterval
    /// Called once per answered question, from a button or from `resolve`. Not for time-outs.
    var onDecision: ((String, Bool) -> Void)?
    /// Called when a question vanished unanswered.
    var onTimeout: ((String) -> Void)?

    private var questions: [String: Question] = [:]
    private var order: [String] = []
    private var shownKey: String?
    private var shownTimeout: Task<Void, Never>?
    /// Which panel the buttons belong to: a click on a panel already replaced must not answer
    /// the next question.
    private var generation = 0

    init(
        presenter: MCPClientApprovalPresenting? = nil,
        questionTimeout: TimeInterval = MCPClientApprovalController.questionTimeout,
        waitLimit: TimeInterval = MCPClientApprovalController.waitLimit
    ) {
        self.presenter = presenter ?? MCPClientApprovalPanel()
        self.questionTimeout = questionTimeout
        self.waitLimit = waitLimit
    }

    var isAsking: Bool { !order.isEmpty }

    func isAsking(about key: String) -> Bool { questions[key] != nil }

    /// Puts the question in line without waiting for the answer: called when a new client
    /// connects, so the panel is up before its first tool call.
    func ask(_ request: MCPClientApprovalRequest) {
        if var question = questions[request.key] {
            question.request = request
            questions[request.key] = question
            return
        }
        questions[request.key] = Question(request: request)
        order.append(request.key)
        showNextIfIdle()
    }

    /// Asks (if not already asking) and waits for the answer, the timeout, or cancellation.
    func decision(for request: MCPClientApprovalRequest) async -> MCPClientApprovalOutcome {
        ask(request)
        let waiterID = UUID()
        let key = request.key
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled, questions[key] != nil else {
                    continuation.resume(returning: Task.isCancelled ? .cancelled : .timedOut)
                    return
                }
                let limit = waitLimit
                let timeout = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(limit))
                    guard !Task.isCancelled else { return }
                    self?.release(waiterID, key: key, with: .timedOut)
                }
                questions[key]?.waiters.append(Waiter(id: waiterID, continuation: continuation, timeout: timeout))
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.release(waiterID, key: key, with: .cancelled) }
        }
    }

    /// An answer given elsewhere (the client list in Settings) closes the question too.
    func resolve(key: String, allowed: Bool) {
        guard questions[key] != nil else { return }
        finish(key: key, outcome: allowed ? .allowed : .denied)
    }

    // MARK: - Private

    private func showNextIfIdle() {
        guard shownKey == nil, let key = order.first, let question = questions[key] else { return }
        shownKey = key
        generation += 1
        let current = generation
        let timeout = questionTimeout
        presenter.show(
            question.request,
            deadline: Date().addingTimeInterval(timeout),
            onAllow: { [weak self] in self?.answer(generation: current, outcome: .allowed) },
            onDeny: { [weak self] in self?.answer(generation: current, outcome: .denied) }
        )
        shownTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            self?.answer(generation: current, outcome: .timedOut)
        }
        MCPDebugLog.log("client approval asked: \(key)")
    }

    private func answer(generation answered: Int, outcome: MCPClientApprovalOutcome) {
        guard answered == generation, let key = shownKey else { return }
        finish(key: key, outcome: outcome)
    }

    private func finish(key: String, outcome: MCPClientApprovalOutcome) {
        guard let question = questions.removeValue(forKey: key) else { return }
        order.removeAll { $0 == key }
        if shownKey == key {
            shownKey = nil
            shownTimeout?.cancel()
            shownTimeout = nil
            generation += 1
            presenter.close()
        }
        for waiter in question.waiters {
            waiter.timeout.cancel()
            waiter.continuation.resume(returning: outcome)
        }
        MCPDebugLog.log("client approval \(key): \(outcome)")
        switch outcome {
        case .allowed: onDecision?(key, true)
        case .denied: onDecision?(key, false)
        case .timedOut: onTimeout?(key)
        case .cancelled: break
        }
        showNextIfIdle()
    }

    private func release(_ waiterID: UUID, key: String, with outcome: MCPClientApprovalOutcome) {
        guard let index = questions[key]?.waiters.firstIndex(where: { $0.id == waiterID }),
              let waiter = questions[key]?.waiters.remove(at: index) else { return }
        waiter.timeout.cancel()
        waiter.continuation.resume(returning: outcome)
    }
}

/// The floating panel in the middle of the screen, built like the meeting confirmation.
@MainActor
final class MCPClientApprovalPanel: MCPClientApprovalPresenting {
    private var panel: NSPanel?

    func show(_ request: MCPClientApprovalRequest, deadline: Date, onAllow: @escaping () -> Void, onDeny: @escaping () -> Void) {
        close()
        let localization = LocalizationService()
        let view = MCPClientApprovalView(
            request: request,
            shownAt: Date(),
            deadline: deadline,
            localization: localization,
            onAllow: onAllow,
            onDeny: onDeny
        )
        .environment(\.locale, localization.locale)
        self.panel = MCPFloatingPanel.present(view, width: 420)
    }

    func close() {
        panel?.close()
        panel = nil
    }
}
