import XCTest
@testable import OWAWidget

/// A conversation brings each message without its quoted history (`UniqueBody`). When that
/// history is nowhere else in the thread — the original of a forward, say — the reader shows
/// the message whole by itself, pictures included, unless its preview shows the text came whole.
@MainActor
final class MailQuotedHistoryTests: XCTestCase {
    private func makeModel(service existing: MailService? = nil, provider existingProvider: FakeMailProvider? = nil) async throws -> (MailWindowModel, FakeMailProvider, FakeMailBackend, MailService) {
        let defaults = UserDefaults(suiteName: "quoted-history-\(UUID().uuidString)")!
        var settings = MailSettings()
        settings.enabled = true
        settings.markReadPolicy = .manual
        settings.save(to: defaults)
        let provider = existingProvider ?? FakeMailProvider(account: MailFixtures.account)
        await provider.setConversations([MailFixtures.conversation("c1")])
        let backend = FakeMailBackend(provider: provider)
        let service = existing ?? MailService(backend: backend, defaults: defaults)
        let model = MailWindowModel(service: service, defaults: defaults)
        await model.reloadList()
        return (model, provider, backend, service)
    }

    private func message(_ id: String, body: String, preview: String = "", isRead: Bool = true, attachments: [MailAttachmentInfo] = [], kind: MailItemKind = .note) -> MailMessage {
        let base = MailFixtures.message(id, conversation: "c1", isRead: isRead, kind: kind)
        return MailMessage(
            ref: base.ref, conversationID: base.conversationID, parentFolderID: base.parentFolderID, kind: kind,
            subject: base.subject, from: base.from, to: [], cc: [], bcc: [], hiddenRecipientCount: 0,
            received: base.received, sent: base.sent, isRead: isRead, isDraft: false, importance: .normal,
            bodyHTML: body, preview: preview, attachments: attachments, categories: [], isFlagged: false,
            actions: base.actions, meeting: nil, internetMessageID: nil
        )
    }

    private let picture = MailAttachmentInfo(id: "A1", name: "image001.png", contentType: "image/png", size: 1, isInline: true, contentID: "shot@01", isItemAttachment: false)
    private let forwarded = #"<p>Regards, Dmitry</p><hr><p><b>From:</b> Dmitry<br><b>Sent:</b> Friday</p><p>Hi all!</p><img src="cid:shot@01">"#

    private let forwardPreview = "Regards, Dmitry From: Dmitry Sent: Friday Hi all!"

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(nanoseconds: 10_000_000) }
    }

    /// Waits for every request the model started to come back: the "message" calls, or none.
    private func settle(_ model: MailWindowModel) async throws {
        try await waitUntil { !model.isPending(.fullBody("m1")) && !model.isPending(.fullBody("m2")) }
        try await Task.sleep(nanoseconds: 50_000_000)
    }

    func testPreviewTellsAWholeTextFromACutOne() {
        XCTAssertTrue(MailMessage.textIsWhole("Hello,\n  see you", preview: "Hello, see you"))
        XCTAssertFalse(MailMessage.textIsWhole("Regards, Dmitry", preview: forwardPreview), "the forward's original was cut")
        XCTAssertFalse(MailMessage.textIsWhole("Hi", preview: ""), "no preview: unknown")
        let long = String(repeating: "word ", count: 60)
        XCTAssertFalse(MailMessage.textIsWhole(long + "more", preview: long), "a preview at its length limit says nothing of the rest")
        XCTAssertTrue(MailMessage.textIsWhole("Hello see you", preview: "Hello, see you"), "a few characters of leeway")
    }

    func testOnlyTheOldestMessageOfAWholeThreadLacksItsHistory() {
        let newest = message("m2", body: "")
        let oldest = message("m1", body: "")
        let whole = MailThread(id: "c1", messages: [newest, oldest], totalMessageCount: 2)
        XCTAssertTrue(whole.lacksQuotedHistory(of: oldest))
        XCTAssertFalse(whole.lacksQuotedHistory(of: newest), "what it quotes is the message below it")

        let partial = MailThread(id: "c1", messages: [newest, oldest], totalMessageCount: 5)
        XCTAssertFalse(partial.lacksQuotedHistory(of: oldest), "older messages exist, not loaded")

        let alone = message("m1", body: "")
        XCTAssertTrue(MailThread(id: "c1", messages: [alone], totalMessageCount: 1).lacksQuotedHistory(of: alone))

        let locked = message("m1", body: "", kind: .protected)
        XCTAssertFalse(MailThread(id: "c1", messages: [locked], totalMessageCount: 1).lacksQuotedHistory(of: locked))
    }

    /// The reported case: a forward alone in its conversation showed only the signature.
    func testForwardAloneInItsConversationShowsWholeWithItsPicture() async throws {
        let (model, provider, backend, _) = try await makeModel()
        _ = backend
        let short = message("m1", body: "<p>Regards, Dmitry</p>", preview: forwardPreview)
        await provider.setThread(MailThread(id: "c1", messages: [short], totalMessageCount: 1))
        await provider.setFullMessage(message("m1", body: forwarded, attachments: [picture]))

        await model.openConversation("c1")
        try await waitUntil { model.fullBodies["m1"] != nil && model.inlineImages["m1"]?["shot@01"] != nil }

        XCTAssertTrue(model.fullBodies["m1"]?.contains("Hi all!") ?? false)
        XCTAssertEqual(model.inlineImages["m1"]?["shot@01"]?.data, Data("x".utf8))
        XCTAssertFalse(model.offersFullBody(short), "nothing left to offer")
        try await settle(model)
        let attachments = await provider.calls.filter { $0 == "attachment" }.count
        XCTAssertEqual(attachments, 1)
    }

    /// The short copy lists the picture too: the scans of the short and the whole text fetch it once.
    func testPictureListedInBothCopiesIsFetchedOnce() async throws {
        let (model, provider, backend, _) = try await makeModel()
        _ = backend
        let short = message("m1", body: "<p>Regards, Dmitry</p>", preview: forwardPreview, attachments: [picture])
        await provider.setThread(MailThread(id: "c1", messages: [short], totalMessageCount: 1))
        await provider.setFullMessage(message("m1", body: forwarded, attachments: [picture]))

        await model.openConversation("c1")
        try await waitUntil { model.fullBodies["m1"] != nil && model.inlineImages["m1"]?["shot@01"] != nil }
        try await settle(model)

        let attachments = await provider.calls.filter { $0 == "attachment" }.count
        XCTAssertEqual(attachments, 1)
    }

    /// Most messages are alone in their conversation: one whose preview its text holds is not read again.
    func testMessageAloneWhoseTextIsWholeIsNotReadAgain() async throws {
        let (model, provider, backend, _) = try await makeModel()
        _ = backend
        let alone = message("m1", body: "<p>Hello, see you</p>", preview: "Hello, see you")
        await provider.setThread(MailThread(id: "c1", messages: [alone], totalMessageCount: 1))

        await model.openConversation("c1")
        try await settle(model)

        let calls = await provider.calls
        XCTAssertFalse(calls.contains("message"), "\(calls)")
        XCTAssertNil(model.fullBodies["m1"])
    }

    /// The whole message is kept by the service: the inbox panel's reader, a new model each
    /// time, does not read it again.
    func testWholeMessageIsReadOnceAcrossReaders() async throws {
        let (model, provider, backend, service) = try await makeModel()
        _ = backend
        await provider.setThread(MailThread(id: "c1", messages: [message("m1", body: "<p>Regards, Dmitry</p>", preview: forwardPreview)], totalMessageCount: 1))
        await provider.setFullMessage(message("m1", body: forwarded))
        await model.openConversation("c1")
        try await waitUntil { model.fullBodies["m1"] != nil }

        let (again, _, _, _) = try await makeModel(service: service, provider: provider)
        await again.openConversation("c1")
        try await waitUntil { again.fullBodies["m1"] != nil }

        XCTAssertTrue(again.fullBodies["m1"]?.contains("Hi all!") ?? false)
        let reads = await provider.calls.filter { $0 == "message" }.count
        XCTAssertEqual(reads, 1)
    }

    /// Outlook copies the pictures of the quoted text into a reply's attachments; the quote is the
    /// message below, so the reply stays short.
    func testReplyCarryingQuotedPicturesStaysShort() async throws {
        let (model, provider, backend, _) = try await makeModel()
        _ = backend
        let reply = message("m2", body: "<p>Thanks</p>", preview: "Thanks From: Dmitry Sent: Friday", attachments: [picture])
        await provider.setThread(MailThread(id: "c1", messages: [reply, message("m1", body: forwarded)], totalMessageCount: 2))

        await model.openConversation("c1")
        try await settle(model)

        let calls = await provider.calls
        XCTAssertFalse(calls.contains("message"), "\(calls)")
        XCTAssertNil(model.fullBodies["m2"])
    }

    /// An ordinary reply: what it quotes is the message below it, so it stays short and the
    /// button is there.
    func testReplyInAWholeThreadStaysShort() async throws {
        let (model, provider, backend, _) = try await makeModel()
        _ = backend
        let reply = message("m2", body: "<p>Thanks</p>")
        await provider.setThread(MailThread(id: "c1", messages: [reply, message("m1", body: "<p>Hello</p>")], totalMessageCount: 2))

        await model.openConversation("c1")
        try await settle(model)

        let calls = await provider.calls
        XCTAssertFalse(calls.contains("message"), "no item was read again: \(calls)")
        XCTAssertNil(model.fullBodies["m2"])
        XCTAssertTrue(model.offersFullBody(reply))
    }

    /// Expanding the oldest message later shows it whole too.
    func testExpandingTheOldestMessageShowsItWhole() async throws {
        let (model, provider, backend, _) = try await makeModel()
        _ = backend
        let oldest = message("m1", body: "<p>Regards, Dmitry</p>")
        await provider.setThread(MailThread(id: "c1", messages: [message("m2", body: "<p>Thanks</p>"), oldest], totalMessageCount: 2))
        await provider.setFullMessage(message("m1", body: forwarded))

        await model.openConversation("c1")
        model.toggleExpanded(oldest)
        try await waitUntil { model.fullBodies["m1"] != nil }

        XCTAssertTrue(model.fullBodies["m1"]?.contains("Hi all!") ?? false)
    }
}
