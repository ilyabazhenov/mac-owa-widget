import XCTest
@testable import OWAWidget

/// Where a row swipe goes for a given travel.
final class MailSwipePolicyTests: XCTestCase {
    func testDirectionWaitsForTravelThenPrefersClearlySideways() {
        XCTAssertEqual(MailSwipePolicy.axis(dx: -3, dy: 1), .undecided)
        XCTAssertEqual(MailSwipePolicy.axis(dx: -12, dy: 2), .horizontal)
        // A slanted scroll through the list stays a scroll.
        XCTAssertEqual(MailSwipePolicy.axis(dx: 8, dy: 7), .vertical)
        XCTAssertEqual(MailSwipePolicy.axis(dx: 1, dy: 10), .vertical)
    }

    func testShortSwipeLeftClosesAndPastHalfTheButtonStaysOpen() {
        let width: CGFloat = 340
        XCTAssertEqual(MailSwipePolicy.outcome(offset: -20, width: width), .close)
        XCTAssertEqual(MailSwipePolicy.outcome(offset: -MailSwipePolicy.revealWidth / 2 - 1, width: width), .reveal)
        XCTAssertEqual(MailSwipePolicy.outcome(offset: -120, width: width), .reveal)
    }

    func testLongSwipeLeftDeletes() {
        let width: CGFloat = 340
        XCTAssertEqual(MailSwipePolicy.outcome(offset: -170, width: width), .delete)
        XCTAssertEqual(MailSwipePolicy.armed(offset: -169, width: width), nil)
        XCTAssertEqual(MailSwipePolicy.armed(offset: -170, width: width), .delete)
    }

    func testNarrowRowStillNeedsALongSwipeToDelete() {
        XCTAssertEqual(MailSwipePolicy.deleteDistance(width: 200), 140)
        XCTAssertEqual(MailSwipePolicy.outcome(offset: -110, width: 200), .reveal)
    }

    func testSwipeRightTogglesReadOnlyPastTheThreshold() {
        XCTAssertEqual(MailSwipePolicy.outcome(offset: 40, width: 340), .close)
        XCTAssertEqual(MailSwipePolicy.outcome(offset: MailSwipePolicy.toggleReadDistance, width: 340), .toggleRead)
    }

    func testRowDoesNotMoveTowardsAnActionItLacks() {
        XCTAssertEqual(MailSwipePolicy.offset(travel: -80, width: 340, canDelete: false, canToggleRead: true), 0)
        XCTAssertEqual(MailSwipePolicy.offset(travel: 80, width: 340, canDelete: true, canToggleRead: false), 0)
        XCTAssertEqual(MailSwipePolicy.offset(travel: -80, width: 340, canDelete: true, canToggleRead: true), -80)
    }

    func testTravelPastTheEndResists() {
        let limit = MailSwipePolicy.toggleReadDistance * 1.5
        let offset = MailSwipePolicy.offset(travel: limit + 100, width: 340, canDelete: true, canToggleRead: true)
        XCTAssertEqual(offset, limit + 25, accuracy: 0.01)
    }
}

/// Swipe actions: delete with Undo and read / unread, in the panel and in the mail window.
@MainActor
final class MailSwipeActionsTests: XCTestCase {
    private func makeService(conversations: [MailConversationSummary]) async throws -> (MailService, FakeMailProvider, FakeMailBackend, UserDefaults) {
        let defaults = UserDefaults(suiteName: "swipe-\(UUID().uuidString)")!
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
        return (service, provider, backend, defaults)
    }

    func testSwipeSettingIsOnByDefaultAndRemembered() {
        let defaults = UserDefaults(suiteName: "swipe-settings-\(UUID().uuidString)")!
        XCTAssertTrue(MailSettings.load(from: defaults).swipeActionsEnabled)
        var settings = MailSettings()
        settings.swipeActionsEnabled = false
        settings.save(to: defaults)
        XCTAssertFalse(MailSettings.load(from: defaults).swipeActionsEnabled)
    }

    func testDeleteKeepsTheNewIdsByTheFolderEachCameFrom() async throws {
        let (service, provider, backend, _) = try await makeService(conversations: [])
        _ = backend
        var fromArchive = MailFixtures.conversation("c2")
        fromArchive = MailConversationSummary(
            id: "c2", topic: "t", senders: [], recipients: [], lastDelivery: nil, messageCount: 1, unreadCount: 0,
            hasAttachments: false, importance: .normal, preview: "", itemRefs: [MailItemRef(id: "I-c2", changeKey: nil)],
            categories: [], isFlagged: false, isProtected: false, instanceKey: nil, parentFolderID: "ARCHIVE"
        )
        let deletion = try await service.delete(conversations: [MailFixtures.conversation("c1"), fromArchive], from: .distinguished(.inbox))
        XCTAssertTrue(deletion.canUndo)
        XCTAssertEqual(deletion.restore[.id("INBOX")], [MailItemRef(id: "I-c1-moved", changeKey: nil)])
        XCTAssertEqual(deletion.restore[.id("ARCHIVE")], [MailItemRef(id: "I-c2-moved", changeKey: nil)])

        try await service.restore(deletion)
        let moves = await provider.moves
        XCTAssertEqual(moves.first?.folder, .distinguished(.deleteditems))
        XCTAssertEqual(Set(moves.dropFirst().map(\.folder)), [.id("INBOX"), .id("ARCHIVE")])
        XCTAssertEqual(Set(moves.dropFirst().flatMap(\.ids)), ["I-c1-moved", "I-c2-moved"])
    }

    func testDeleteWithoutNewIdsCannotBeUndone() async throws {
        let (service, provider, backend, _) = try await makeService(conversations: [])
        _ = backend
        await provider.setMoveReturnsIDs(false)
        let deletion = try await service.delete(conversations: [MailFixtures.conversation("c1")], from: .distinguished(.inbox))
        XCTAssertFalse(deletion.canUndo)
    }

    func testPanelDeleteLeavesTheListAndUndoPutsItBack() async throws {
        let (service, provider, backend, _) = try await makeService(conversations: [
            MailFixtures.conversation("c1"), MailFixtures.conversation("c2"), MailFixtures.conversation("c3"),
        ])
        _ = backend
        await service.refreshPanelList(minInterval: 0)
        await service.deletePanelConversation(service.panelList[1])
        XCTAssertEqual(service.panelList.map(\.id), ["c1", "c3"])
        guard case .deleted(let deletion, let positions, _)? = service.panelNotice else { return XCTFail("no Undo offered") }
        XCTAssertEqual(positions["c2"], 1)
        XCTAssertTrue(deletion.canUndo)

        await service.undoPanelDelete()
        XCTAssertNil(service.panelNotice)
        XCTAssertEqual(service.panelList.map(\.id), ["c1", "c2", "c3"])
        let moves = await provider.moves
        XCTAssertEqual(moves.map(\.folder), [.distinguished(.deleteditems), .id("INBOX")])
        XCTAssertEqual(moves.last?.ids, ["I-c2-moved"])
    }

    func testPanelAnimatesOnlyRowsASwipeTookOrUndoPutBack() async throws {
        let (service, _, backend, _) = try await makeService(conversations: [
            MailFixtures.conversation("c1"), MailFixtures.conversation("c2"), MailFixtures.conversation("c3"),
        ])
        _ = backend
        await service.refreshPanelList(minInterval: 0)
        await service.refreshPanelList(minInterval: 0)
        XCTAssertEqual(service.panelRowsRevision, 0, "a refresh lands without animating the list")
        await service.deletePanelConversation(service.panelList[1])
        XCTAssertEqual(service.panelRowsRevision, 1)
        await service.undoPanelDelete()
        XCTAssertEqual(service.panelRowsRevision, 2)
    }

    /// The popover (the whole calendar) redraws for mail only when what it shows of mail changes.
    func testPopoverChromeIgnoresPanelAndCountChangesAndFollowsSettings() async throws {
        let (service, provider, backend, _) = try await makeService(conversations: [
            MailFixtures.conversation("c1"), MailFixtures.conversation("c2"),
        ])
        _ = backend
        await drainMainQueue()
        var publishes = 0
        let subscription = service.popoverChrome.objectWillChange.sink { publishes += 1 }
        defer { subscription.cancel() }

        // Rows coming and leaving, the Undo line, the unread count (the envelope's badge follows
        // it on its own): none of it redraws the popover.
        await service.refreshPanelList(minInterval: 0)
        await service.togglePanelRead(service.panelList[1])
        await service.deletePanelConversation(service.panelList[0])
        await provider.setConversations([MailFixtures.conversation("c2")])
        await service.checkInbox()
        await drainMainQueue()
        XCTAssertEqual(publishes, 0)

        service.updateSettings { $0.popoverSectionEnabled = false }
        await drainMainQueue()
        XCTAssertEqual(publishes, 1)
        XCTAssertFalse(service.popoverChrome.value.showsPopoverSection)
        XCTAssertTrue(service.popoverChrome.value.isAvailable)
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    func testRefusedPanelDeletePutsTheRowBack() async throws {
        let (service, provider, backend, _) = try await makeService(conversations: [
            MailFixtures.conversation("c1"), MailFixtures.conversation("c2"),
        ])
        _ = backend
        await service.refreshPanelList(minInterval: 0)
        await provider.setFailure(URLError(.notConnectedToInternet))
        await service.deletePanelConversation(service.panelList[0])
        XCTAssertEqual(service.panelList.map(\.id), ["c1", "c2"])
        XCTAssertEqual(service.panelNotice, .failed)
    }

    func testPanelSwipeRightMarksReadAndBackUnread() async throws {
        let (service, provider, backend, _) = try await makeService(conversations: [MailFixtures.conversation("c1", unread: 2)])
        _ = backend
        await service.refreshPanelList(minInterval: 0)
        await service.togglePanelRead(service.panelList[0])
        XCTAssertEqual(service.panelList.first?.unreadCount, 0)
        await service.togglePanelRead(service.panelList[0])
        XCTAssertEqual(service.panelList.first?.unreadCount, 1)
        let count = await provider.updateCount
        // Read: both messages; unread: the newest only.
        XCTAssertEqual(count, 2)
    }

    func testRefusedPanelReadGoesBack() async throws {
        let (service, provider, backend, _) = try await makeService(conversations: [MailFixtures.conversation("c1", unread: 2)])
        _ = backend
        await service.refreshPanelList(minInterval: 0)
        await provider.setFailure(URLError(.timedOut))
        await service.togglePanelRead(service.panelList[0])
        XCTAssertEqual(service.panelList.first?.unreadCount, 2)
        XCTAssertEqual(service.panelNotice, .failed)
    }

    func testWindowDeleteOffersUndoThatBringsTheRowBack() async throws {
        let (service, provider, backend, defaults) = try await makeService(conversations: [
            MailFixtures.conversation("c1"), MailFixtures.conversation("c2"),
        ])
        _ = backend
        let model = MailWindowModel(service: service, defaults: defaults)
        await model.loadFolders()
        await model.reloadList()
        await model.delete([model.conversations[0]])
        XCTAssertEqual(model.conversations.map(\.id), ["c2"])
        guard case .deleted? = model.listNotice else { return XCTFail("no Undo offered") }

        await model.undoDelete()
        XCTAssertNil(model.listNotice)
        XCTAssertEqual(model.conversations.map(\.id), ["c1", "c2"])
        let moves = await provider.moves
        XCTAssertEqual(moves.last?.folder, .id("INBOX"))
    }

    func testDeletedItemsRowsHaveNoDeleteSwipe() async throws {
        let (service, _, backend, defaults) = try await makeService(conversations: [MailFixtures.conversation("c1")])
        _ = backend
        let model = MailWindowModel(service: service, defaults: defaults)
        await model.loadFolders()
        XCTAssertFalse(model.isInDeletedItems(MailFixtures.conversation("c1")))
        model.selectedFolder = .distinguished(.deleteditems)
        XCTAssertTrue(model.isInDeletedItems(MailFixtures.conversation("c1")))
    }
}
