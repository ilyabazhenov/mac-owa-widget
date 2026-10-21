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

    func testReplyAllToANoteToSelfGoesBackToTheUser() {
        let base = original()
        let note = MailMessage(
            ref: base.ref, conversationID: base.conversationID, parentFolderID: base.parentFolderID, kind: .note,
            subject: "Note", from: MailAddress(name: "Alex Morgan", email: "a.morgan@example.com"),
            to: [MailAddress(name: "Alex Morgan", email: "A.Morgan@example.com")], cc: [],
            bcc: [], hiddenRecipientCount: 0, received: Date(), sent: Date(), isRead: true, isDraft: false, importance: .normal,
            bodyHTML: "<p>x</p>", preview: "x", attachments: [], categories: [], isFlagged: false, actions: [], meeting: nil, internetMessageID: nil
        )
        let request = MailComposeDraftBuilder.request(.replyAll, from: note, ownAddress: "a.morgan@example.com")
        XCTAssertEqual(request.to, ["a.morgan@example.com"])
        XCTAssertTrue(request.cc.isEmpty)
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

    func testChipsShowNamesAndDropTheOwnDomain() {
        let model = MailComposeModel(request: MailComposeDraftBuilder.request(.replyAll, from: original(), ownAddress: "a.morgan@example.com"), service: service)
        XCTAssertEqual(model.chipLabel("g.miller@example.com"), "Grace Miller")
        XCTAssertEqual(model.chipLabel("T.Wright@partner.example"), "Partner", "names match the address in any case")
        model.toInput = "x.doe@example.com, y@other.example, z@sub.example.com"
        model.commit(.to)
        XCTAssertEqual(model.chipLabel("x.doe@example.com"), "x.doe", "a typed address of the user's domain loses only the domain")
        XCTAssertEqual(model.chipLabel("y@other.example"), "y@other.example", "an external address stays whole")
        XCTAssertEqual(model.chipLabel("z@sub.example.com"), "z@sub.example.com")
        XCTAssertEqual(MailComposeModel.chipLabel("a@example.com", name: "a@example.com", ownDomain: "example.com"), "a", "an address given as the name is no name")
        XCTAssertEqual(MailComposeModel.shortName("Попов  Александр Васильевич"), "Попов Александр")
        XCTAssertEqual(MailComposeModel.shortName("Иванова Мария Ильинична"), "Иванова Мария")
        XCTAssertEqual(MailComposeModel.shortName("Mary Ann Smith"), "Mary Ann Smith")
        XCTAssertEqual(MailComposeModel.shortName("Сидоров Пётр"), "Сидоров Пётр")
    }

    func testPickedPersonKeepsTheirName() async {
        backend.people = [ResolvedAttendee(displayName: "Попов Александр Васильевич", email: "APopov@example.com", jobTitle: nil)]
        let model = MailComposeModel(request: MailComposeRequest(kind: .new, original: nil, to: [], cc: [], subject: "", body: ""), service: service)
        model.toInput = "Попов"
        model.inputChanged(.to)
        await waitForSuggestions(model)
        model.submit(.to)
        XCTAssertEqual(model.to, ["APopov@example.com"])
        XCTAssertEqual(model.chipLabel("APopov@example.com"), "Попов Александр")
    }

    func testLongListFoldsButKeepsFlaggedAddresses() {
        let list = (1...12).map { "p\($0)@example.com" } + ["out@partner.example"]
        let flagged = { (address: String) in address.hasSuffix("partner.example") }
        let folded = MailComposeModel.collapsed(list, limit: 8, flagged: flagged)
        XCTAssertEqual(folded.shown, Array(list.prefix(7)) + ["out@partner.example"])
        XCTAssertEqual(folded.hidden, 5)
        XCTAssertEqual(folded.shown.count + folded.hidden, list.count)
        let nine = Array(list.prefix(9))
        XCTAssertEqual(MailComposeModel.collapsed(nine, limit: 8, flagged: flagged).hidden, 0, "one left out is not worth a chip")
        XCTAssertEqual(MailComposeModel.collapsed(Array(list.prefix(10)), limit: 8, flagged: flagged).hidden, 2)
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

    func testMailtoLinkKeepsSubjectBodyAndRecipients() throws {
        let url = try XCTUnwrap(URL(string: "mailto:approve@corp.ru,Desk%20%3Cdesk@corp.ru%3E?Subject=%D0%A1%D0%BE%D0%B3%D0%BB%D0%B0%D1%81%D0%BE%D0%B2%D0%B0%D1%82%D1%8C%20C12932859&cc=a@corp.ru&to=APPROVE@corp.ru&body=line%201%0D%0Aa+b%26c&bcc=hidden@corp.ru"))
        let request = try XCTUnwrap(MailComposeRequest.mailto(url))
        XCTAssertEqual(request.kind, .new)
        XCTAssertEqual(request.to, ["approve@corp.ru", "desk@corp.ru"])
        XCTAssertEqual(request.cc, ["a@corp.ru"])
        XCTAssertEqual(request.subject, "Согласовать C12932859")
        XCTAssertEqual(request.body, "line 1\na+b&c")
    }

    func testMailtoLinkWithAddressOnly() throws {
        let request = try XCTUnwrap(MailComposeRequest.mailto(XCTUnwrap(URL(string: "MAILTO:user+tag@corp.ru"))))
        XCTAssertEqual(request.to, ["user+tag@corp.ru"])
        XCTAssertEqual(request.subject, "")
        XCTAssertEqual(request.body, "")
        XCTAssertNil(MailComposeRequest.mailto(try XCTUnwrap(URL(string: "https://corp.ru"))))
        XCTAssertEqual(MailComposeRequest.mailto(try XCTUnwrap(URL(string: "mailto:?subject=Hi")))?.to, [])
    }
}
