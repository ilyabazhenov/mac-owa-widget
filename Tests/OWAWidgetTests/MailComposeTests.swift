import XCTest
@testable import OWAWidget

@MainActor
final class MailComposeTests: XCTestCase {
    private var provider: FakeMailProvider!
    private var backend: FakeMailBackend!
    private var service: MailService!

    override func setUp() async throws {
        let defaults = UserDefaults(suiteName: "MailComposeTests-\(UUID().uuidString)")!
        var settings = MailSettings()
        settings.enabled = true
        settings.save(to: defaults)
        provider = FakeMailProvider(account: MailFixtures.account)
        backend = FakeMailBackend(provider: provider)
        service = MailService(backend: backend, defaults: defaults)
        await service.resolveOwnAddress()
    }

    private func original() -> MailMessage {
        let base = MailFixtures.message("M1", conversation: "C1")
        return MailMessage(
            ref: base.ref, conversationID: base.conversationID, parentFolderID: base.parentFolderID, kind: .note,
            subject: "Release 1.3", from: MailAddress(name: "Grace Miller", email: "g.miller@example.com"),
            to: [MailAddress(name: "Alex Morgan", email: "a.morgan@example.com"), MailAddress(name: "Noah", email: "n.bennett@example.com")],
            cc: [MailAddress(name: "Partner", email: "t.wright@partner.example"), MailAddress(name: "Me again", email: "A.Morgan@example.com")],
            bcc: [], hiddenRecipientCount: 0, received: Date(), sent: Date(), isRead: true, isDraft: false, importance: .normal,
            bodyHTML: "<p>x</p>", preview: "x", attachments: [], categories: [], isFlagged: false, actions: [], meeting: nil, internetMessageID: nil
        )
    }

    func testReplyAllLeavesTheUserOut() {
        let request = MailComposeDraftBuilder.request(.replyAll, from: original(), ownAddress: "a.morgan@example.com")
        XCTAssertEqual(request.to, ["g.miller@example.com", "n.bennett@example.com"])
        XCTAssertEqual(request.cc, ["t.wright@partner.example"])
        XCTAssertEqual(request.subject, "RE: Release 1.3")
        let reply = MailComposeDraftBuilder.request(.reply, from: original(), ownAddress: "a.morgan@example.com")
        XCTAssertEqual(reply.to, ["g.miller@example.com"])
        XCTAssertTrue(reply.cc.isEmpty)
        let forward = MailComposeDraftBuilder.request(.forward, from: original(), ownAddress: nil)
        XCTAssertTrue(forward.to.isEmpty)
        XCTAssertEqual(forward.subject, "FW: Release 1.3")
    }

    func testUntouchedReplySubjectIsLeftToExchange() {
        let model = MailComposeModel(request: MailComposeDraftBuilder.request(.reply, from: original(), ownAddress: nil), service: service)
        XCTAssertEqual(model.outgoing(send: true).subject, "")
        model.subject = "RE: Release 1.3 — moved"
        XCTAssertEqual(model.outgoing(send: true).subject, "RE: Release 1.3 — moved")
        XCTAssertEqual(model.outgoing(send: true).reference, MailItemRef(id: "M1", changeKey: "CK"))
    }

    func testExternalAndInvalidRecipients() {
        let model = MailComposeModel(request: MailComposeDraftBuilder.request(.replyAll, from: original(), ownAddress: "a.morgan@example.com"), service: service)
        XCTAssertEqual(model.externalDomains, ["partner.example"])
        model.toInput = "not-an-address, x@sub.example.com"
        model.commit(.to)
        XCTAssertEqual(model.invalidRecipients, ["not-an-address"])
        XCTAssertFalse(model.canSend)
        XCTAssertFalse(service.isExternal("x@sub.example.com"), "a subdomain of the user's domain is internal")
    }

    func testUndoStopsTheSend() async throws {
        let model = MailComposeModel(request: MailComposeDraftBuilder.request(.reply, from: original(), ownAddress: nil), service: service)
        model.body = "Thanks"
        model.send()
        try await Task.sleep(for: .milliseconds(200))
        guard case .countdown = model.phase else { return XCTFail("expected the countdown, got \(model.phase)") }
        model.undo()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(model.phase, .editing)
        let sent = await provider.sent
        XCTAssertTrue(sent.isEmpty)
    }

    func testDraftGoesToTheProviderAsSaveOnly() async throws {
        let model = MailComposeModel(request: MailComposeRequest(kind: .new, original: nil, to: ["g.miller@example.com"], cc: [], subject: "Plan", body: "Hi"), service: service)
        model.saveDraft()
        for _ in 0..<20 where model.phase != .done(.new, sent: false) { try await Task.sleep(for: .milliseconds(50)) }
        let sent = await provider.sent
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.send, false)
        XCTAssertEqual(sent.first?.subject, "Plan")
    }
}
