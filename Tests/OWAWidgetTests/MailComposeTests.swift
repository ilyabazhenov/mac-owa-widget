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
        let drafts = await provider.drafts
        XCTAssertTrue(sent.isEmpty)
        XCTAssertEqual(drafts.count, 1)
        XCTAssertEqual(drafts.first?.send, false)
        XCTAssertEqual(drafts.first?.subject, "Plan")
    }

    // MARK: - Draft, review, send

    func testSendGoesThroughAReviewedDraft() async throws {
        let outgoing = MailComposeModel(request: MailComposeDraftBuilder.request(.reply, from: original(), ownAddress: "a.morgan@example.com"), service: service).outgoing(send: true)
        let prepared = try await service.prepareSend(outgoing)
        XCTAssertTrue(prepared.matchesRequest)
        var sent = await provider.sent
        XCTAssertTrue(sent.isEmpty, "nothing goes out before the draft is reviewed")
        try await service.sendPrepared(prepared)
        sent = await provider.sent
        XCTAssertEqual(sent.map(\.to), [["g.miller@example.com"]])
        let calls = await provider.calls
        XCTAssertEqual(calls.suffix(3), ["send", "draftReview", "sendDraft"])
    }

    func testRecipientsExchangeAddsAreCaught() async throws {
        await provider.setDraftExtraRecipients([MailAddress(name: "Grace", email: "grace@evil.example"), MailAddress(name: "Legacy", email: nil)])
        let outgoing = MailComposeModel(request: MailComposeDraftBuilder.request(.reply, from: original(), ownAddress: nil), service: service).outgoing(send: true)
        let prepared = try await service.prepareSend(outgoing)
        XCTAssertFalse(prepared.matchesRequest)
        XCTAssertEqual(prepared.addedRecipients.map(\.name), ["Grace", "Legacy"], "an address the server does not give counts as added")
        await service.discardPrepared(prepared)
        let sent = await provider.sent
        let deleted = await provider.deletedDrafts
        XCTAssertTrue(sent.isEmpty)
        XCTAssertEqual(deleted, [prepared.draft.id])
    }

    func testCutShortRecipientListIsNotSent() async throws {
        await provider.setDraftHiddenRecipients(3)
        let outgoing = MailOutgoing(kind: .new, reference: nil, to: ["g.miller@example.com"], cc: [], subject: "x", body: "y")
        do {
            _ = try await service.prepareSend(outgoing)
            XCTFail("expected recipientsUnverified")
        } catch {
            XCTAssertEqual(error as? MailError, .recipientsUnverified)
        }
        let deleted = await provider.deletedDrafts
        XCTAssertEqual(deleted.count, 1, "the unreadable draft does not stay behind")
    }

    private func waitForSuggestions(_ model: MailComposeModel) async {
        for _ in 0..<100 where model.isSearchingPeople { try? await Task.sleep(for: .milliseconds(20)) }
    }

    func testReturnPicksTheHighlightedSuggestionNotTheTypedName() async {
        backend.people = [
            ResolvedAttendee(displayName: "Каретко Владислав", email: "VKaretko@example.com", jobTitle: nil),
            ResolvedAttendee(displayName: "Каретко Анна", email: "AKaretko@example.com", jobTitle: nil),
        ]
        let model = MailComposeModel(request: MailComposeRequest(kind: .new, original: nil, to: [], cc: [], subject: "", body: ""), service: service)
        model.toInput = "Каретко"
        model.inputChanged(.to)
        XCTAssertTrue(model.showsSuggestions(for: .to), "the dropdown says it is searching")
        await waitForSuggestions(model)
        XCTAssertEqual(model.suggestions.count, 2)
        model.moveHighlight(by: 1)
        model.submit(.to)
        XCTAssertEqual(model.to, ["AKaretko@example.com"])
        XCTAssertEqual(model.toInput, "")
        XCTAssertFalse(model.showsSuggestions(for: .to))
    }

    func testReturnDoesNotPickAPersonFoundForOlderText() async {
        backend.people = [
            ResolvedAttendee(displayName: "Каретко Владислав", email: "VKaretko@example.com", jobTitle: nil),
            ResolvedAttendee(displayName: "Каретко Анна", email: "AKaretko@example.com", jobTitle: nil),
        ]
        let model = MailComposeModel(request: MailComposeRequest(kind: .new, original: nil, to: [], cc: [], subject: "", body: ""), service: service)
        model.toInput = "Кар"
        model.inputChanged(.to)
        await waitForSuggestions(model)
        XCTAssertEqual(model.suggestions.count, 2)
        // More typed, and Return before the new search answers: the list is the old text's.
        model.toInput = "Каретко Анна"
        model.inputChanged(.to)
        model.submit(.to)
        XCTAssertTrue(model.to.isEmpty, "nobody is picked from the previous search")
        XCTAssertEqual(model.toInput, "Каретко Анна")
    }

    func testNobodyFoundIsShownAndReturnKeepsWhatWasTyped() async {
        let model = MailComposeModel(request: MailComposeRequest(kind: .new, original: nil, to: [], cc: [], subject: "", body: ""), service: service)
        model.ccInput = "Никто"
        model.inputChanged(.cc)
        await waitForSuggestions(model)
        XCTAssertTrue(model.foundNoPeople)
        XCTAssertTrue(model.showsSuggestions(for: .cc))
        XCTAssertFalse(model.showsSuggestions(for: .to))
        model.submit(.cc)
        XCTAssertEqual(model.cc, ["Никто"])
    }

    func testPastedPicturesAreSentAndOversizedOnesBlockSending() {
        let request = MailComposeRequest(kind: .new, original: nil, to: ["g.miller@example.com"], cc: [], subject: "s", body: "")
        let model = MailComposeModel(request: request, service: service)
        model.body = "see \u{FFFC}"
        model.bodyImages = [MailInlineImage(contentID: "a", name: "a.png", contentType: "image/png", data: Data([1]))]
        XCTAssertEqual(model.outgoing(send: true).inlineImages, model.bodyImages)
        XCTAssertTrue(model.canSend)
        model.bodyImages = [MailInlineImage(name: "big.png", contentType: "image/png", data: Data(count: MailInlineImage.maxTotalBytes + 1))]
        XCTAssertTrue(model.imagesTooLarge)
        XCTAssertFalse(model.canSend)
    }
}
