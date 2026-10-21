import XCTest
@testable import OWAWidget

/// Reading a message in the inbox panel beside the popover.
@MainActor
final class InboxPanelReaderTests: XCTestCase {
    private func makeService(conversations: [MailConversationSummary]) async throws -> (MailService, FakeMailProvider, FakeMailBackend) {
        let defaults = UserDefaults(suiteName: "panel-reader-\(UUID().uuidString)")!
        var settings = MailSettings()
        settings.enabled = true
        settings.save(to: defaults)
        let provider = FakeMailProvider(account: MailFixtures.account)
        await provider.setFolders([
            MailFolder(id: "INBOX", distinguishedID: "inbox", displayName: "Inbox", parentID: nil, unreadCount: 2, totalCount: 10, childFolderCount: 0),
            MailFolder(id: "TRASH", distinguishedID: "deleteditems", displayName: "Deleted Items", parentID: nil, unreadCount: 0, totalCount: 0, childFolderCount: 0),
        ])
        await provider.setConversations(conversations)
        let backend = FakeMailBackend(provider: provider)
        let service = MailService(backend: backend, defaults: defaults)
        try await service.loadFolders()
        await service.refreshPanelList(minInterval: 0)
        return (service, provider, backend)
    }

    func testNeighborWalksTheListAndStopsAtItsEnds() {
        let list = ["a", "b", "c"]
        XCTAssertEqual(InboxPanelReader.neighbor(of: "b", step: 1, in: list), "c")
        XCTAssertEqual(InboxPanelReader.neighbor(of: "b", step: -1, in: list), "a")
        XCTAssertNil(InboxPanelReader.neighbor(of: "c", step: 1, in: list))
        XCTAssertNil(InboxPanelReader.neighbor(of: "a", step: -1, in: list))
        // A conversation a refresh took out of the list has no neighbours.
        XCTAssertNil(InboxPanelReader.neighbor(of: "x", step: 1, in: list))
        XCTAssertNil(InboxPanelReader.neighbor(of: nil, step: 1, in: list))
    }

    func testOpenStepAndCloseKeepTheLastReadRow() async throws {
        let (service, _, backend) = try await makeService(conversations: [
            MailFixtures.conversation("c1"), MailFixtures.conversation("c2"),
        ])
        _ = backend
        let reader = InboxPanelReader()
        reader.open("c1", in: service.panelFolder, service: service)
        XCTAssertTrue(reader.isOpen)
        XCTAssertNotNil(reader.model)
        XCTAssertTrue(service.isPanelReaderOpen)

        XCTAssertTrue(reader.step(1, service: service))
        XCTAssertEqual(reader.conversationID, "c2")
        XCTAssertFalse(reader.step(1, service: service))
        XCTAssertFalse(reader.canStep(1, in: service.panelList))
        XCTAssertTrue(reader.canStep(-1, in: service.panelList))

        reader.close()
        XCTAssertFalse(reader.isOpen)
        XCTAssertNil(reader.model)
        XCTAssertFalse(service.isPanelReaderOpen)
        XCTAssertEqual(reader.lastOpenedID, "c2")

        reader.close(forget: true)
        XCTAssertNil(reader.lastOpenedID)
    }

    func testReadingInThePanelMarksItsRowRead() async throws {
        let (service, provider, backend) = try await makeService(conversations: [MailFixtures.conversation("c1", unread: 1)])
        _ = backend
        await provider.setThread(MailThread(id: "c1", messages: [MailFixtures.message("m1", conversation: "c1")], totalMessageCount: 1))
        let reader = InboxPanelReader()
        reader.open("c1", in: service.panelFolder, service: service)
        let model = try XCTUnwrap(reader.model)
        await model.openConversation("c1")
        let message = try XCTUnwrap(model.thread?.messages.first)

        await model.setRead(message, true)
        XCTAssertEqual(service.panelList.first?.unreadCount, 0)
        await model.setRead(try XCTUnwrap(model.thread?.messages.first), false)
        XCTAssertEqual(service.panelList.first?.unreadCount, 1)
    }

    func testReadingACopyInAnotherFolderLeavesTheRowAlone() async throws {
        let (service, provider, backend) = try await makeService(conversations: [MailFixtures.conversation("c1", unread: 1)])
        _ = backend
        let inboxMessage = MailFixtures.message("m1", conversation: "c1")
        let elsewhere = MailMessage(
            ref: MailItemRef(id: "m2", changeKey: "CK"), conversationID: "c1", parentFolderID: "ARCHIVE", kind: .note,
            subject: "Subject", from: inboxMessage.from, to: [], cc: [], bcc: [], hiddenRecipientCount: 0,
            received: Date(), sent: Date(), isRead: false, isDraft: false, importance: .normal,
            bodyHTML: "<p>Hi</p>", preview: "Hi", attachments: [], categories: [], isFlagged: false,
            actions: [.reply], meeting: nil, internetMessageID: nil
        )
        await provider.setThread(MailThread(id: "c1", messages: [elsewhere, inboxMessage], totalMessageCount: 2))

        try await service.setRead(elsewhere, true)
        XCTAssertEqual(service.panelList.first?.unreadCount, 1)
        try await service.setRead(inboxMessage, true)
        XCTAssertEqual(service.panelList.first?.unreadCount, 0)
    }
}
