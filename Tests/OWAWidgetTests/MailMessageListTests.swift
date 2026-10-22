import XCTest
@testable import OWAWidget

/// Grouping by conversation turned off: lists show every message as a row of its own, and a row
/// opens that message alone.
@MainActor
final class MailMessageListTests: XCTestCase {
    private var defaults: UserDefaults!
    private var provider: FakeMailProvider!
    private var backend: FakeMailBackend!

    override func setUp() async throws {
        defaults = UserDefaults(suiteName: "MailMessageListTests-\(UUID().uuidString)")
        provider = FakeMailProvider(account: MailFixtures.account)
        backend = FakeMailBackend(provider: provider)
        await provider.setFolders([
            MailFolder(id: "INBOX", distinguishedID: "inbox", displayName: "Inbox", parentID: nil, unreadCount: 2, totalCount: 10, childFolderCount: 0),
        ])
        await provider.setConversations([MailFixtures.conversation("CV1", unread: 2)])
        await provider.setUnreadItems([Self.item("I1", isRead: false), Self.item("I2", isRead: true)])
    }

    private static func item(_ id: String, isRead: Bool) -> MailListItem {
        var item = MailListItem(
            ref: MailItemRef(id: id, changeKey: "CK"), conversationID: "CV1", subject: "Release",
            from: MailAddress(name: "Grace Miller", email: "g.miller@example.com"), displayTo: "Alex Morgan",
            received: Date(), isRead: isRead, hasAttachments: false, importance: .normal, preview: "Hi", instanceKey: "K-\(id)"
        )
        item.itemClass = "IPM.Note"
        item.parentFolderID = "INBOX"
        return item
    }

    private func makeService(grouped: Bool) -> MailService {
        var settings = MailSettings()
        settings.enabled = true
        settings.groupByConversation = grouped
        settings.save(to: defaults)
        return MailService(backend: backend, defaults: defaults)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 where !condition() {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func testSettingIsOnByDefaultAndRemembered() {
        XCTAssertTrue(MailSettings.load(from: defaults).groupByConversation, "conversations, as before")
        var settings = MailSettings()
        settings.groupByConversation = false
        settings.save(to: defaults)
        XCTAssertFalse(MailSettings.load(from: defaults).groupByConversation)
    }

    func testPanelListsMessagesWhenGroupingIsOff() async {
        let service = makeService(grouped: false)
        await service.refreshPanelList(minInterval: 0)
        XCTAssertEqual(service.panelList.map(\.id), ["I1", "I2"])
        XCTAssertTrue(service.panelList.allSatisfy(\.isSingleMessage))
        let calls = await provider.calls
        XCTAssertEqual(calls, ["items"], "FindItem, not FindConversation")
    }

    func testSwitchingGroupingReloadsThePanel() async throws {
        let service = makeService(grouped: true)
        await service.refreshPanelList(minInterval: 0)
        XCTAssertEqual(service.panelList.map(\.id), ["CV1"])
        service.updateSettings { $0.groupByConversation = false }
        XCTAssertFalse(service.panelList.contains { $0.id == "CV1" }, "a conversation row is not a message row")
        try await waitUntil { service.panelList.map(\.id) == ["I1", "I2"] }
        XCTAssertEqual(service.panelList.map(\.id), ["I1", "I2"])
    }

    func testReadingAMessageUpdatesItsOwnRowOnly() async throws {
        let service = makeService(grouped: false)
        await service.refreshPanelList(minInterval: 0)
        let message = MailFixtures.message("I1", conversation: "CV1")
        try await service.setRead(message, true)
        XCTAssertEqual(service.panelList.first { $0.id == "I1" }?.unreadCount, 0)
        XCTAssertEqual(service.panelList.first { $0.id == "I2" }?.unreadCount, 0, "the other message was read already")
        let other = MailFixtures.message("I2", conversation: "CV1", isRead: true)
        try await service.setRead(other, false)
        XCTAssertEqual(service.panelList.first { $0.id == "I2" }?.unreadCount, 1)
        XCTAssertEqual(service.panelList.first { $0.id == "I1" }?.unreadCount, 0)
    }

    func testWindowOpensAMessageRowAlone() async throws {
        let service = makeService(grouped: false)
        await provider.setFullMessage(MailFixtures.message("I1", conversation: "CV1"))
        try await service.loadFolders()
        let model = MailWindowModel(service: service, defaults: defaults)
        await model.reloadList()
        XCTAssertEqual(model.conversations.map(\.id), ["I1", "I2"])

        await model.openConversation("I1")
        XCTAssertEqual(model.thread?.id, "I1")
        XCTAssertEqual(model.thread?.messages.map(\.ref.id), ["I1"])
        let calls = await provider.calls
        XCTAssertTrue(calls.contains("message"))
        XCTAssertFalse(calls.contains("thread"), "the conversation is not read")

        // Opened again: from the cache.
        model.clearSelection()
        await model.openConversation("I1")
        let messageCalls = await provider.calls.filter { $0 == "message" }
        XCTAssertEqual(messageCalls.count, 1)
    }

    func testAConversationIDStillOpensItsThread() async throws {
        // A notification or the meeting card names a conversation, whatever the list shows.
        let service = makeService(grouped: false)
        await provider.setThread(MailThread(id: "CV1", messages: [MailFixtures.message("I1", conversation: "CV1")], totalMessageCount: 1))
        let model = MailWindowModel(service: service, defaults: defaults)
        await model.reloadList()
        await model.openConversation("CV1")
        XCTAssertEqual(model.thread?.id, "CV1")
        let calls = await provider.calls
        XCTAssertTrue(calls.contains("thread"))
    }

    func testSwitchingGroupingReloadsTheWindowList() async throws {
        let service = makeService(grouped: true)
        await provider.setThread(MailThread(id: "CV1", messages: [MailFixtures.message("I1", conversation: "CV1")], totalMessageCount: 1))
        let model = MailWindowModel(service: service, defaults: defaults)
        await model.reloadList()
        await model.openConversation("CV1")
        XCTAssertEqual(model.conversations.map(\.id), ["CV1"])

        service.updateSettings { $0.groupByConversation = false }
        try await waitUntil { model.conversations.map(\.id) == ["I1", "I2"] }
        XCTAssertEqual(model.conversations.map(\.id), ["I1", "I2"])
        XCTAssertNil(model.selectedConversationID, "the open conversation is not a row any more")
    }

    func testSearchAsksForMessagesWhenGroupingIsOff() async throws {
        let service = makeService(grouped: false)
        let model = MailWindowModel(service: service, defaults: defaults)
        model.searchFilters.text = "release"
        await model.submitSearch()
        XCTAssertEqual(model.activeSearch?.asMessages, true)
    }

    // MARK: - Paging

    func testWindowPagesMessagesWithTheItemCursor() async throws {
        await provider.setUnreadItems([Self.item("I1", isRead: false), Self.item("I2", isRead: true), Self.item("I3", isRead: true)])
        await provider.setItemPageSize(2)
        let service = makeService(grouped: false)
        let model = MailWindowModel(service: service, defaults: defaults)
        await model.reloadList()
        XCTAssertEqual(model.conversations.map(\.id), ["I1", "I2"])
        XCTAssertTrue(model.canLoadMore)
        await model.loadMore()
        XCTAssertEqual(model.conversations.map(\.id), ["I1", "I2", "I3"])
        XCTAssertFalse(model.canLoadMore)
        let cursors = await provider.itemCursors
        XCTAssertEqual(cursors, [.first, .after(instanceKey: "2")])
        let calls = await provider.calls
        XCTAssertFalse(calls.contains { $0.hasPrefix("conversations") }, "the next page is messages too")
    }

    func testPanelPagesMessagesWithTheItemCursor() async throws {
        await provider.setUnreadItems([Self.item("I1", isRead: false), Self.item("I2", isRead: true), Self.item("I3", isRead: true)])
        await provider.setItemPageSize(2)
        let service = makeService(grouped: false)
        await service.refreshPanelList(minInterval: 0)
        XCTAssertEqual(service.panelList.map(\.id), ["I1", "I2"])
        XCTAssertNotNil(service.panelNextCursor)
        await service.loadMorePanelList()
        XCTAssertEqual(service.panelList.map(\.id), ["I1", "I2", "I3"])
        XCTAssertNil(service.panelNextCursor)
        let cursors = await provider.itemCursors
        XCTAssertEqual(cursors, [.first, .after(instanceKey: "2")])
    }

    func testPanelDropsAConversationPageThatLandsAfterTheSwitch() async throws {
        await provider.setConversations([MailFixtures.conversation("CV1"), MailFixtures.conversation("CV2")])
        await provider.setConversationPageSize(1)
        let service = makeService(grouped: true)
        await service.refreshPanelList(minInterval: 0)
        XCTAssertEqual(service.panelList.map(\.id), ["CV1"])

        // The next conversation page is on its way when grouping goes off.
        await provider.setConversationDelays([300_000_000])
        let more = Task { await service.loadMorePanelList() }
        try await Task.sleep(nanoseconds: 50_000_000)
        service.updateSettings { $0.groupByConversation = false }
        await more.value
        try await waitUntil { service.panelList.map(\.id) == ["I1", "I2"] }
        XCTAssertEqual(service.panelList.map(\.id), ["I1", "I2"], "no conversation row among the messages")
    }

    func testWindowDropsAConversationPageThatLandsAfterTheSwitch() async throws {
        await provider.setConversations([MailFixtures.conversation("CV1"), MailFixtures.conversation("CV2")])
        await provider.setConversationPageSize(1)
        let service = makeService(grouped: true)
        let model = MailWindowModel(service: service, defaults: defaults)
        await model.reloadList()
        XCTAssertEqual(model.conversations.map(\.id), ["CV1"])

        await provider.setConversationDelays([300_000_000])
        let more = Task { await model.loadMore() }
        try await Task.sleep(nanoseconds: 50_000_000)
        service.updateSettings { $0.groupByConversation = false }
        await more.value
        try await waitUntil { model.conversations.map(\.id) == ["I1", "I2"] }
        XCTAssertEqual(model.conversations.map(\.id), ["I1", "I2"])
    }

    // MARK: - Review fixes

    func testReadingOneMessageKeepsItsConversationUnreadWhileOthersAre() async throws {
        await provider.setConversations([MailFixtures.conversation("CV1", unread: 2)])
        await provider.setUnreadItems([Self.item("I1", isRead: false), Self.item("I2", isRead: false)])
        await provider.setUnread(2)
        let service = makeService(grouped: false)
        await service.checkInbox()
        XCTAssertEqual(service.peopleUnread.map(\.id), ["CV1"])
        await service.refreshPanelList(minInterval: 0)

        let first = try XCTUnwrap(service.panelList.first { $0.id == "I1" })
        try await service.setRead(conversations: [first], true)
        XCTAssertEqual(service.peopleUnread.map(\.id), ["CV1"], "I2 is still unread")
        XCTAssertEqual(service.peopleUnread.first?.unreadCount, 1)

        let second = try XCTUnwrap(service.panelList.first { $0.id == "I2" })
        _ = try await service.delete(conversations: [second], from: .distinguished(.inbox))
        XCTAssertTrue(service.peopleUnread.isEmpty, "nothing unread is left in it")
        XCTAssertTrue(service.latestUnread.isEmpty)
    }

    func testReadingAMessageInTheReaderTakesOneOffItsConversation() async throws {
        await provider.setConversations([MailFixtures.conversation("CV1", unread: 2)])
        await provider.setUnread(2)
        let service = makeService(grouped: false)
        await service.checkInbox()
        try await service.setRead(MailFixtures.message("I1", conversation: "CV1"), true)
        XCTAssertEqual(service.peopleUnread.first?.unreadCount, 1)
        try await service.setRead(MailFixtures.message("I2", conversation: "CV1"), true)
        XCTAssertTrue(service.peopleUnread.isEmpty)
    }

    func testConversationActionDropsItsMessagesOpenedAlone() async throws {
        await provider.setFullMessage(MailFixtures.message("I1", conversation: "CV1"))
        let service = makeService(grouped: false)
        _ = try await service.messageThread(MailItemRef(id: "I1", changeKey: nil))
        service.updateSettings { $0.groupByConversation = true }
        let conversation = MailConversationSummary(
            id: "CV1", topic: "Release", senders: ["Grace Miller"], recipients: [], lastDelivery: Date(), messageCount: 2,
            unreadCount: 0, hasAttachments: false, importance: .normal, preview: "Hi",
            itemRefs: [MailItemRef(id: "I1", changeKey: "CK"), MailItemRef(id: "I2", changeKey: "CK")],
            categories: [], isFlagged: false, isProtected: false, instanceKey: "K", parentFolderID: "INBOX"
        )
        try await service.setRead(conversations: [conversation], false)
        service.updateSettings { $0.groupByConversation = false }
        _ = try await service.messageThread(MailItemRef(id: "I1", changeKey: nil))
        let reads = await provider.calls.filter { $0 == "message" }
        XCTAssertEqual(reads.count, 2, "the copy cached before the change is not shown again")
    }

    func testSnapshotKeepsTheGroupingItsRowsWereLoadedWith() async throws {
        let service = makeService(grouped: false)
        let model = MailWindowModel(service: service, defaults: defaults)
        await model.reloadList()
        XCTAssertEqual(model.conversations.map(\.id), ["I1", "I2"])
        service.updateSettings { $0.groupByConversation = true }
        try await waitUntil { model.conversations.map(\.id) == ["CV1"] }

        // Grouping goes off and, before the list reloads, a change lands on the conversation
        // rows; then the server is unreachable.
        await provider.setFailure(URLError(.notConnectedToInternet))
        service.updateSettings { $0.groupByConversation = false }
        await model.flag(model.conversations, true)
        try await waitUntil { model.staleList != nil }
        XCTAssertEqual(model.conversations.map(\.id), ["I1", "I2"], "the messages loaded earlier, not the conversations")
    }

    func testDeletingAMessageRowMovesThatMessageOnly() async throws {
        let service = makeService(grouped: false)
        await service.refreshPanelList(minInterval: 0)
        let row = try XCTUnwrap(service.panelList.first { $0.id == "I1" })
        _ = try await service.delete(conversations: [row], from: .distinguished(.inbox))
        let moves = await provider.moves
        XCTAssertEqual(moves.map(\.ids), [["I1"]])
    }
}
