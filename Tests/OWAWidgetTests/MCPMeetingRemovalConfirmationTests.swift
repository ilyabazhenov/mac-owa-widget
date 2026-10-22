import XCTest
@testable import OWAWidget

/// The cancel_meeting question over the shared `MCPConfirmationWaiter`, with a fake panel.
@MainActor
final class MCPMeetingRemovalConfirmationTests: XCTestCase {
    private final class FakePresenter: MCPMeetingRemovalPresenting {
        private(set) var shown = 0
        private(set) var closed = 0
        private(set) var deadlines: [Date] = []
        var onConfirm: (() -> Void)?
        var onReject: (() -> Void)?

        func show(_ proposal: MCPMeetingRemovalProposal, deadline: Date, onConfirm: @escaping () -> Void, onReject: @escaping () -> Void) {
            shown += 1
            deadlines.append(deadline)
            self.onConfirm = onConfirm
            self.onReject = onReject
        }

        func close() { closed += 1 }
    }

    private let proposal = MCPMeetingRemovalProposal(
        mode: .decline, title: "t", start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 1800),
        location: "", organizer: "Org", attendees: [], unaddressedAttendees: [], message: "", isOccurrence: false,
        isAlreadyCancelled: false, isAlreadyDeclined: false, client: "", externalCheckAvailable: true
    )

    private func waitUntilShown(_ presenter: FakePresenter, count: Int = 1) async {
        for _ in 0..<200 where presenter.shown < count {
            await Task.yield()
        }
    }

    func testButtonsAnswerAndClosePanel() async {
        for (press, expected) in [({ (p: FakePresenter) in p.onConfirm?() }, MCPConfirmationOutcome.confirmed), ({ $0.onReject?() }, .rejected)] {
            let presenter = FakePresenter()
            let controller = MCPMeetingRemovalConfirmationController(presenter: presenter)
            let answer = Task { await controller.confirm(proposal, timeout: 30) }
            await waitUntilShown(presenter)

            press(presenter)

            let outcome = await answer.value
            XCTAssertEqual(outcome, expected)
            XCTAssertEqual(presenter.closed, 1)
        }
    }

    func testDeadlineFollowsTheTimeoutItWasGiven() async {
        let presenter = FakePresenter()
        let controller = MCPMeetingRemovalConfirmationController(presenter: presenter)
        let before = Date()
        let answer = Task { await controller.confirm(proposal, timeout: 38) }
        await waitUntilShown(presenter)
        presenter.onReject?()
        _ = await answer.value

        let deadline = try? XCTUnwrap(presenter.deadlines.first)
        XCTAssertEqual(deadline?.timeIntervalSince(before) ?? 0, 38, accuracy: 1)
    }

    func testNoAnswerTimesOutAndALateClickChangesNothing() async {
        let presenter = FakePresenter()
        let controller = MCPMeetingRemovalConfirmationController(presenter: presenter)

        let outcome = await controller.confirm(proposal, timeout: 0.05)

        XCTAssertEqual(outcome, .timedOut)
        presenter.onConfirm?()
        XCTAssertEqual(presenter.closed, 1)
    }

    func testClientCancellationClosesThePanel() async {
        let presenter = FakePresenter()
        let controller = MCPMeetingRemovalConfirmationController(presenter: presenter)
        let answer = Task { await controller.confirm(proposal, timeout: 30) }
        await waitUntilShown(presenter)

        answer.cancel()

        let outcome = await answer.value
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(presenter.closed, 1)
    }
}
