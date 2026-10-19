import XCTest
@testable import OWAWidget

/// List and message actions show at once and go back when the server refuses them.
@MainActor
final class MailOptimisticActionsTests: XCTestCase {
    private func makeModel(conversations: [MailConversationSummary]) async throws -> (MailWindowModel, FakeMailProvider, FakeMailBackend) {
        let defaults = UserDefaults(suiteName: "optimistic-\(UUID().uuidString)")!
        var settings = MailSettings()
        settings.enabled = true
        settings.save(to: defaults)
        let provider = FakeMailProvider(account: MailFixtures.account)
        await provider.setFolders([
            MailFolder(id: "INBOX", distinguishedID: "inbox", displayName: "Inbox", parentID: nil, unreadCount: 2, totalCount: 10, childFolderCount: 0),
        ])
        await provider.setConversations(conversations)
        let backend = FakeMailBackend(provider: provider)
        let service = MailService(backend: backend, defaults: defaults)
        try await service.loadFolders()
        let model = MailWindowModel(service: service, defaults: defaults)
        await model.loadFolders()
        await model.reloadList()
        return (model, provider, backend)
    }

    func testRefusedMarkReadPutsTheRowAndCounterBack() async throws {
        let (model, provider, backend) = try await makeModel(conversations: [MailFixtures.conversation("c1", unread: 2)])
        _ = backend
        await provider.setFailure(URLError(.notConnectedToInternet))
        await model.markRead(model.conversations, true)
        XCTAssertEqual(model.conversations.first?.unreadCount, 2)
        XCTAssertEqual(model.folders.first { $0.id == "INBOX" }?.unreadCount, 2)
        XCTAssertNotNil(model.actionError)
    }

    func testRefusedFlagComesOff() async throws {
        let (model, provider, backend) = try await makeModel(conversations: [MailFixtures.conversation("c1")])
        _ = backend
        await provider.setFailure(URLError(.timedOut))
        await model.flag(model.conversations, true)
        XCTAssertEqual(model.conversations.first?.isFlagged, false)
    }

    func testMoveLeavesTheListAtOnceAndOpensTheNext() async throws {
        let (model, provider, backend) = try await makeModel(conversations: [MailFixtures.conversation("c1"), MailFixtures.conversation("c2")])
        _ = backend
        await provider.setThread(MailThread(id: "c1", messages: [MailFixtures.message("m1", conversation: "c1")], totalMessageCount: 1))
        await provider.setThread(MailThread(id: "c2", messages: [MailFixtures.message("m2", conversation: "c2")], totalMessageCount: 1))
        await model.openConversation("c1")
        await model.move([try XCTUnwrap(model.conversations.first)], to: .distinguished(.deleteditems))
        XCTAssertEqual(model.conversations.map(\.id), ["c2"])
        XCTAssertEqual(model.selectedConversationID, "c2")
    }

    func testRefusedMoveBringsTheConversationBackInItsPlace() async throws {
        let (model, provider, backend) = try await makeModel(conversations: [
            MailFixtures.conversation("c1"), MailFixtures.conversation("c2"), MailFixtures.conversation("c3"),
        ])
        _ = backend
        await provider.setFailure(URLError(.notConnectedToInternet))
        await model.move([model.conversations[1]], to: .distinguished(.deleteditems))
        XCTAssertEqual(model.conversations.map(\.id), ["c1", "c2", "c3"])
        XCTAssertNotNil(model.actionError)
    }

    func testRefusedMessageFlagGoesBack() async throws {
        let (model, provider, backend) = try await makeModel(conversations: [MailFixtures.conversation("c1")])
        _ = backend
        await provider.setThread(MailThread(id: "c1", messages: [MailFixtures.message("m1", conversation: "c1", isRead: true)], totalMessageCount: 1))
        await model.openConversation("c1")
        let message = try XCTUnwrap(model.thread?.messages.first)

        await model.setFlag(message, true)
        XCTAssertEqual(model.thread?.messages.first?.isFlagged, true)

        await provider.setFailure(URLError(.timedOut))
        await model.setFlag(try XCTUnwrap(model.thread?.messages.first), false)
        XCTAssertEqual(model.thread?.messages.first?.isFlagged, true, "the refused change is undone")
    }

    func testASecondChangeRightAfterTheFirstIsNotLost() async throws {
        let (model, provider, backend) = try await makeModel(conversations: [MailFixtures.conversation("c1")])
        _ = backend
        await provider.setThread(MailThread(id: "c1", messages: [MailFixtures.message("m1", conversation: "c1", isRead: true)], totalMessageCount: 1))
        await model.openConversation("c1")
        let message = try XCTUnwrap(model.thread?.messages.first)

        // Both clicks before either answer: the second still holds the message as first shown.
        let flag = Task { await model.setFlag(message, true) }
        let category = Task { await model.toggleCategory("Red", on: message) }
        await flag.value
        await category.value

        let shown = try XCTUnwrap(model.thread?.messages.first)
        XCTAssertTrue(shown.isFlagged)
        XCTAssertEqual(shown.categories, ["Red"])
        let refs = await provider.updates.map(\.0.changeKey)
        XCTAssertEqual(refs, ["CK", "CK+"], "the second change goes with the change key the first got back")
        XCTAssertEqual(shown.ref.changeKey, "CK++")
    }

    /// The second change is refused: the cached thread keeps only what the server accepted.
    func testARefusedSecondChangeStaysOutOfTheCache() async throws {
        let (model, provider, backend) = try await makeModel(conversations: [MailFixtures.conversation("c1")])
        _ = backend
        await provider.setThread(MailThread(id: "c1", messages: [MailFixtures.message("m1", conversation: "c1", isRead: true)], totalMessageCount: 1))
        await model.openConversation("c1")
        let message = try XCTUnwrap(model.thread?.messages.first)
        await provider.setUpdatesBeforeFailure(1)

        let flag = Task { await model.setFlag(message, true) }
        await Task.yield()  // the flag is the first change of the run
        let category = Task { await model.toggleCategory("Red", on: message) }
        await flag.value
        await category.value

        let shown = try XCTUnwrap(model.thread?.messages.first)
        XCTAssertTrue(shown.isFlagged)
        XCTAssertEqual(shown.categories, [], "the refused category comes off the screen")
        XCTAssertNotNil(model.actionError)
        let cached = try await model.service.thread("c1")
        let copy = try XCTUnwrap(cached.messages.first)
        XCTAssertTrue(copy.isFlagged)
        XCTAssertEqual(copy.categories, [], "the refused category is not in the cached copy either")
        XCTAssertEqual(copy.ref.changeKey, "CK+")
    }

    /// A message with no pictures is not marked as done: the quoted history loaded later is
    /// looked at again, and its picture shows.
    func testPicturesInTheQuotedHistoryLoad() async throws {
        let (model, provider, backend) = try await makeModel(conversations: [MailFixtures.conversation("c1")])
        _ = backend
        let short = MailFixtures.message("m1", conversation: "c1", isRead: true)
        await provider.setThread(MailThread(id: "c1", messages: [short], totalMessageCount: 1))
        await model.openConversation("c1")
        for _ in 0..<200 where model.inlineImages["m1"] != nil { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNil(model.inlineImages["m1"], "nothing to load: left for a later look")

        let attachment = MailAttachmentInfo(id: "A1", name: "image001.png", contentType: "image/png", size: 1, isInline: true, contentID: "shot@01", isItemAttachment: false)
        await provider.setFullMessage(MailMessage(
            ref: short.ref, conversationID: short.conversationID, parentFolderID: short.parentFolderID, kind: short.kind,
            subject: short.subject, from: short.from, to: short.to, cc: short.cc, bcc: short.bcc, hiddenRecipientCount: 0,
            received: short.received, sent: short.sent, isRead: true, isDraft: false, importance: .normal,
            bodyHTML: #"<p>Hi</p><blockquote><img src="cid:shot@01"></blockquote>"#, preview: "Hi", attachments: [attachment],
            categories: [], isFlagged: false, actions: [], meeting: nil, internetMessageID: nil
        ))
        await model.loadFullBody(short)
        for _ in 0..<200 where model.inlineImages["m1"]?.isEmpty ?? true { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(model.inlineImages["m1"]?["shot@01"]?.data, Data("x".utf8))
    }

    func testRefreshIsPendingOnlyWhileItRuns() async throws {
        let (model, _, backend) = try await makeModel(conversations: [MailFixtures.conversation("c1")])
        _ = backend
        XCTAssertFalse(model.isPending(.refresh))
        await model.refresh()
        XCTAssertFalse(model.isPending(.refresh))
    }
}
