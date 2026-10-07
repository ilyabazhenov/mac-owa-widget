import XCTest
@testable import OWAWidget

/// The "allow this client?" question: one answer per client, shared by every waiting call, one
/// panel at a time, and nothing read before Allow.
@MainActor
final class MCPClientApprovalTests: XCTestCase {
    private final class FakePresenter: MCPClientApprovalPresenting {
        var shown: [String] = []
        var closeCount = 0
        var allow: (() -> Void)?
        var deny: (() -> Void)?

        func show(_ request: MCPClientApprovalRequest, deadline: Date, onAllow: @escaping () -> Void, onDeny: @escaping () -> Void) {
            shown.append(request.key)
            allow = onAllow
            deny = onDeny
        }

        func close() { closeCount += 1 }
    }

    private func request(_ key: String) -> MCPClientApprovalRequest {
        MCPClientApprovalRequest(key: key, name: key, executablePath: "/bin/\(key)", script: nil, kind: .bridge,
                                 declaredName: nil, canCreateMeetings: false)
    }

    /// Lets queued main-actor work (the waiters registering) run.
    private func settle() async {
        for _ in 0..<5 { await Task.yield() }
    }

    func testEveryWaitingCallGetsTheOneAnswer() async {
        let presenter = FakePresenter()
        let controller = MCPClientApprovalController(presenter: presenter)
        var decisions: [(String, Bool)] = []
        controller.onDecision = { decisions.append(($0, $1)) }

        let asked = request("a")
        let first = Task { await controller.decision(for: asked) }
        let second = Task { await controller.decision(for: asked) }
        await settle()
        XCTAssertEqual(presenter.shown, ["a"], "one panel for one client")
        presenter.allow?()

        let outcomes = [await first.value, await second.value]
        XCTAssertEqual(outcomes, [.allowed, .allowed])
        XCTAssertEqual(decisions.map(\.0), ["a"])
        XCTAssertEqual(decisions.map(\.1), [true])
        XCTAssertFalse(controller.isAsking)
    }

    func testDenyIsRecorded() async {
        let presenter = FakePresenter()
        let controller = MCPClientApprovalController(presenter: presenter)
        var allowed: Bool?
        controller.onDecision = { _, value in allowed = value }

        let asked = request("a")
        let outcome = Task { await controller.decision(for: asked) }
        await settle()
        presenter.deny?()
        let result = await outcome.value
        XCTAssertEqual(result, .denied)
        XCTAssertEqual(allowed, false)
    }

    func testSecondClientWaitsForTheFirstPanel() async {
        let presenter = FakePresenter()
        let controller = MCPClientApprovalController(presenter: presenter)
        controller.ask(request("a"))
        controller.ask(request("b"))
        XCTAssertEqual(presenter.shown, ["a"])

        presenter.deny?()
        XCTAssertEqual(presenter.shown, ["a", "b"], "b comes up once a is answered")
        XCTAssertTrue(controller.isAsking(about: "b"))
        XCTAssertFalse(controller.isAsking(about: "a"))
    }

    func testStaleButtonDoesNotAnswerTheNextQuestion() async {
        let presenter = FakePresenter()
        let controller = MCPClientApprovalController(presenter: presenter)
        controller.ask(request("a"))
        let staleAllow = presenter.allow
        controller.ask(request("b"))
        presenter.deny?()                 // a denied, b on screen
        staleAllow?()                     // a late click on a's panel
        XCTAssertTrue(controller.isAsking(about: "b"))
    }

    func testAnswerFromSettingsClosesTheQuestion() async {
        let presenter = FakePresenter()
        let controller = MCPClientApprovalController(presenter: presenter)
        let asked = request("a")
        let outcome = Task { await controller.decision(for: asked) }
        await settle()
        controller.resolve(key: "a", allowed: true)
        let result = await outcome.value
        XCTAssertEqual(result, .allowed)
        XCTAssertEqual(presenter.closeCount, 1)
    }

    func testUnansweredQuestionTimesOut() async {
        let presenter = FakePresenter()
        let controller = MCPClientApprovalController(presenter: presenter, questionTimeout: 0.05, waitLimit: 5)
        var timedOutKey: String?
        var decided = false
        controller.onTimeout = { timedOutKey = $0 }
        controller.onDecision = { _, _ in decided = true }

        let outcome = await controller.decision(for: request("a"))
        XCTAssertEqual(outcome, .timedOut)
        XCTAssertEqual(timedOutKey, "a")
        XCTAssertFalse(decided, "silence is not an answer")
        XCTAssertFalse(controller.isAsking)
    }

    func testWaiterGivesUpButTheQuestionStays() async {
        let presenter = FakePresenter()
        let controller = MCPClientApprovalController(presenter: presenter, questionTimeout: 60, waitLimit: 0.05)
        let outcome = await controller.decision(for: request("a"))
        XCTAssertEqual(outcome, .timedOut)
        XCTAssertTrue(controller.isAsking(about: "a"), "the user can still answer for the next run")
    }

    func testCancelledCallLeavesTheQuestionOpen() async {
        let presenter = FakePresenter()
        let controller = MCPClientApprovalController(presenter: presenter)
        let asked = request("a")
        let task = Task { await controller.decision(for: asked) }
        await settle()
        task.cancel()
        let outcome = await task.value
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertTrue(controller.isAsking(about: "a"))
    }

    // MARK: - Policy and stored list

    func testPolicy() {
        XCTAssertEqual(MCPClientAccessPolicy.verdict(for: nil, askNewClients: true), .ask)
        XCTAssertEqual(MCPClientAccessPolicy.verdict(for: .pending, askNewClients: true), .ask)
        XCTAssertEqual(MCPClientAccessPolicy.verdict(for: .allowed, askNewClients: true), .allow)
        XCTAssertEqual(MCPClientAccessPolicy.verdict(for: .denied, askNewClients: true), .deny)
        // With the question off: unknown and undecided clients read, denied ones stay out.
        XCTAssertEqual(MCPClientAccessPolicy.verdict(for: nil, askNewClients: false), .allow)
        XCTAssertEqual(MCPClientAccessPolicy.verdict(for: .pending, askNewClients: false), .allow)
        XCTAssertEqual(MCPClientAccessPolicy.verdict(for: .denied, askNewClients: false), .deny)
    }

    func testClientsSavedBeforeTheQuestionStayAllowed() throws {
        let json = #"[{"key":"k","name":"Claude Code","executablePath":"/x","lastKind":"bridge","firstSeen":0,"lastSeen":0}]"#
        let list = try JSONDecoder().decode([MCPKnownClient].self, from: Data(json.utf8))
        XCTAssertEqual(list.first?.access, .allowed)
    }

    func testNewClientIsRecordedPendingAndKeepsItsDecision() {
        let identity = MCPClientIdentity(key: "k", name: "node", executablePath: "/node", script: nil, kind: .bridge, pid: 1)
        var list = MCPKnownClientList.record(identity, at: Date(), in: [], newClientAccess: .pending).list
        XCTAssertEqual(list.first?.access, .pending)
        list = MCPKnownClientList.setAccess(.denied, forKey: "k", in: list)
        list = MCPKnownClientList.record(identity, at: Date(), in: list, newClientAccess: .pending).list
        XCTAssertEqual(list.first?.access, .denied, "a later connection does not reset the decision")
    }
}
