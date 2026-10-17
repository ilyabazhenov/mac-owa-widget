import XCTest
@testable import OWAWidget

/// A mailbox in memory. Records every call; sends nothing anywhere.
actor FakeMailProvider: MailProvider {
    nonisolated let account: CalendarAccount
    var unread = 3
    var conversations: [MailConversationSummary] = []
    var threads: [String: MailThread] = [:]
    var folderList: [MailFolder] = []
    var searchPages: [MailSearchPage] = []
    var failure: Error?
    private(set) var calls: [String] = []
    private(set) var sent: [MailOutgoing] = []
    private(set) var updates: [(MailItemRef, MailItemUpdate)] = []

    init(account: CalendarAccount) { self.account = account }

    func setUnread(_ value: Int) { unread = value }
    func setFailure(_ error: Error?) { failure = error }
    func setConversations(_ value: [MailConversationSummary]) { conversations = value }
    func setThread(_ thread: MailThread) { threads[thread.id] = thread }
    func setFolders(_ value: [MailFolder]) { folderList = value }
    func setSearchPages(_ value: [MailSearchPage]) { searchPages = value }

    private func record(_ name: String) throws {
        calls.append(name)
        if let failure { throw failure }
    }

    func mailFolders() async throws -> [MailFolder] { try record("folders"); return folderList }

    func mailFolderCounts(_ folders: [MailFolderRef]) async throws -> [MailFolder] {
        try record("counts")
        let inbox = MailFolder(id: "INBOX", distinguishedID: "inbox", displayName: "Inbox", parentID: nil, unreadCount: unread, totalCount: 100, childFolderCount: 0)
        return folders.compactMap { ref in
            switch ref {
            case .distinguished(.inbox): return inbox
            case .id(let id): return folderList.first { $0.id == id }
            default: return nil
            }
        }
    }

    func mailConversations(in folder: MailFolderRef, cursor: MailListCursor, filter: MailListFilter) async throws -> MailConversationPage {
        try record("conversations:\(filter.rawValue)")
        return MailConversationPage(conversations: conversations, totalInView: conversations.count, nextCursor: nil)
    }

    var unreadItems: [MailListItem] = []
    func setUnreadItems(_ value: [MailListItem]) { unreadItems = value }

    func mailItems(in folder: MailFolderRef, cursor: MailListCursor, filter: MailListFilter, count: Int) async throws -> MailItemPage {
        try record("items")
        let page = Array(unreadItems.prefix(count))
        return MailItemPage(items: page, totalInView: unreadItems.count, nextCursor: unreadItems.count > count ? .after(instanceKey: "next") : nil)
    }

    func mailThread(conversationID: String, ignoringFolders: [String]) async throws -> MailThread {
        try record("thread")
        guard let thread = threads[conversationID] else { throw MailError.notFound }
        return thread
    }

    func mailMessage(_ ref: MailItemRef) async throws -> MailMessage {
        try record("message")
        guard let message = threads.values.flatMap(\.messages).first(where: { $0.ref.id == ref.id }) else { throw MailError.notFound }
        return message
    }

    func mailAttachment(id: String, maxBytes: Int) async throws -> Data { try record("attachment"); return Data("x".utf8) }

    func mailUpdate(_ refs: [MailItemRef], _ update: MailItemUpdate) async throws -> [MailItemRef] {
        try record("update")
        for ref in refs { updates.append((ref, update)) }
        if case .isRead(true) = update {
            let marked = Set(refs.map(\.id))
            unreadItems.removeAll { marked.contains($0.ref.id) }
        }
        return refs.map { MailItemRef(id: $0.id, changeKey: ($0.changeKey ?? "") + "+") }
    }
    var updateCount: Int { updates.count }

    func mailMove(_ refs: [MailItemRef], to folder: MailFolderRef) async throws -> [MailItemRef] {
        try record("move")
        return refs.map { MailItemRef(id: $0.id + "-moved", changeKey: nil) }
    }

    func mailSearch(_ query: MailSearchQuery, offset: Int, count: Int) async throws -> MailSearchPage {
        try record("search")
        return searchPages.isEmpty ? MailSearchPage(conversations: [], moreAvailable: false, searchTerms: [], refiners: [], offset: offset) : searchPages.removeFirst()
    }

    func mailEndSearch() async { calls.append("endSearch") }

    func mailSend(_ outgoing: MailOutgoing) async throws -> MailItemRef? {
        try record("send")
        sent.append(outgoing)
        return nil
    }
}

@MainActor
final class FakeMailBackend: MailBackend {
    var accounts: [CalendarAccount]
    var providers: [UUID: FakeMailProvider]
    var isMailBlocked = false
    var reported: [String] = []

    init(provider: FakeMailProvider) {
        accounts = [provider.account]
        providers = [provider.account.id: provider]
    }

    var mailAccounts: [CalendarAccount] { accounts }
    func mailProvider(accountID: UUID) -> (any MailProvider)? { providers[accountID] }
    func reportMailFailure(_ error: Error, context: String) { reported.append(context) }
    func ownMailAddress(accountID: UUID) async -> String? { "a.morgan@example.com" }
    func findMailPeople(query: String, accountID: UUID) async throws -> [ResolvedAttendee] { [] }
    var vipNames: Set<String> = []
    var meetingAnswers: [(String, MeetingResponseAction)] = []
    var knownMeetings: Set<String> = []
    func respondToMailMeeting(calendarItemID: String, action: MeetingResponseAction) async throws -> Bool {
        guard knownMeetings.contains(calendarItemID) else { return false }
        meetingAnswers.append((calendarItemID, action))
        return true
    }
    func mailMeetingResponse(calendarItemID: String) -> MeetingResponseType? { nil }
    var mailVIPNames: Set<String> { vipNames }
}

enum MailFixtures {
    static let account = CalendarAccount(id: UUID(), displayName: "Work", serverURL: "https://mail.example.com", email: "EXAMPLE\\user", accountType: .owa)

    static func conversation(_ id: String, unread: Int = 1) -> MailConversationSummary {
        MailConversationSummary(
            id: id, topic: "Topic \(id)", senders: ["Grace Miller"], recipients: [], lastDelivery: Date(), messageCount: 1,
            unreadCount: unread, hasAttachments: false, importance: .normal, preview: "Hi", itemRefs: [MailItemRef(id: "I-\(id)", changeKey: "CK")],
            categories: [], isFlagged: false, isProtected: false, instanceKey: "K-\(id)", parentFolderID: "INBOX"
        )
    }

    static func message(_ id: String, conversation: String, isRead: Bool = false) -> MailMessage {
        MailMessage(
            ref: MailItemRef(id: id, changeKey: "CK"), conversationID: conversation, parentFolderID: "INBOX", kind: .note,
            subject: "Subject", from: MailAddress(name: "Grace Miller", email: "g.miller@example.com"), to: [], cc: [], bcc: [],
            hiddenRecipientCount: 0, received: Date(), sent: Date(), isRead: isRead, isDraft: false, importance: .normal,
            bodyHTML: "<p>Hello</p>", preview: "Hello", attachments: [], categories: [], isFlagged: false,
            actions: [.reply, .replyAll, .forward], meeting: nil, internetMessageID: nil
        )
    }
}

@MainActor
final class MailServiceTests: XCTestCase {
    private var defaults: UserDefaults!
    private var provider: FakeMailProvider!
    private var backend: FakeMailBackend!

    override func setUp() async throws {
        defaults = UserDefaults(suiteName: "MailServiceTests-\(UUID().uuidString)")
        provider = FakeMailProvider(account: MailFixtures.account)
        backend = FakeMailBackend(provider: provider)
    }

    private func makeService(enabled: Bool = true) -> MailService {
        var settings = MailSettings()
        settings.enabled = enabled
        settings.save(to: defaults)
        return MailService(backend: backend, defaults: defaults)
    }

    func testDisabledMailMakesNoRequests() async throws {
        let service = makeService(enabled: false)
        await service.checkInbox()
        do {
            _ = try await service.thread("C1")
            XCTFail("expected an error")
        } catch {}
        let calls = await provider.calls
        XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(service.menuBarUnreadCount, 0)
    }

    func testCheckInboxReadsCountAndUnreadList() async {
        await provider.setConversations([MailFixtures.conversation("A"), MailFixtures.conversation("B", unread: 0)])
        let service = makeService()
        await service.checkInbox()
        XCTAssertEqual(service.inboxUnreadCount, 3)
        XCTAssertEqual(service.latestUnread.map(\.id), ["A"])
        let calls = await provider.calls
        XCTAssertEqual(calls, ["counts", "conversations:Unread"])

        // Same count: only the cheap request.
        await service.checkInbox()
        let again = await provider.calls
        XCTAssertEqual(again, ["counts", "conversations:Unread", "counts"])
    }

    func testBlockedSyncStopsMail() async {
        backend.isMailBlocked = true
        let service = makeService()
        await service.checkInbox()
        XCTAssertEqual(service.checkState, .blocked)
        do {
            _ = try await service.search(MailSearchQuery(text: "x"), offset: 0)
            XCTFail("expected an error")
        } catch {
            guard case MailError.blocked = error else { return XCTFail("\(error)") }
        }
        let calls = await provider.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testFailuresReachTheCircuitBreaker() async {
        await provider.setFailure(OWAError.httpError(401, "stale"))
        let service = makeService()
        await service.checkInbox()
        XCTAssertEqual(backend.reported, ["mail.checkInbox"])
        guard case .failed = service.checkState else { return XCTFail("expected failure") }
    }

    func testThreadIsCachedAndSetReadUpdatesIt() async throws {
        await provider.setThread(MailThread(id: "C1", messages: [MailFixtures.message("M1", conversation: "C1")], totalMessageCount: 1))
        let service = makeService()
        await service.checkInbox()
        let first = try await service.thread("C1")
        _ = try await service.thread("C1")
        let threadCalls = await provider.calls.filter { $0 == "thread" }
        XCTAssertEqual(threadCalls.count, 1)

        let updated = try await service.setRead(first.messages[0], true)
        XCTAssertTrue(updated.isRead)
        XCTAssertEqual(updated.ref.changeKey, "CK+", "the next change needs the new change key")
        XCTAssertEqual(service.inboxUnreadCount, 2)
        let cached = try await service.thread("C1")
        XCTAssertTrue(cached.messages[0].isRead)
    }

    func testMoveEvictsTheThread() async throws {
        await provider.setThread(MailThread(id: "C1", messages: [MailFixtures.message("M1", conversation: "C1")], totalMessageCount: 1))
        let service = makeService()
        let thread = try await service.thread("C1")
        try await service.move(thread.messages, to: .distinguished(.deleteditems))
        _ = try await service.thread("C1")
        let threadCalls = await provider.calls.filter { $0 == "thread" }
        XCTAssertEqual(threadCalls.count, 2)
    }

    func testSendPassesTheMessageThrough() async throws {
        let service = makeService()
        let outgoing = MailOutgoing(kind: .reply, reference: MailItemRef(id: "M1", changeKey: "CK"), to: ["a@example.com"], cc: [], subject: "", body: "Hi")
        try await service.send(outgoing)
        let sent = await provider.sent
        XCTAssertEqual(sent, [outgoing])
    }

    func testMenuBarBadgeFollowsSetting() async {
        let service = makeService()
        await service.checkInbox()
        XCTAssertEqual(service.menuBarUnreadCount, 0)
        service.updateSettings { $0.menuBarBadgeEnabled = true }
        XCTAssertEqual(service.menuBarUnreadCount, 0, "people only by default: nothing unread from people here")
        service.updateSettings { $0.peopleOnly = false }
        XCTAssertEqual(service.menuBarUnreadCount, 3, "everything unread in the inbox")
        XCTAssertTrue(MailSettings.load(from: defaults).menuBarBadgeEnabled)
    }

    func testFolderOrder() {
        func folder(_ id: String, _ name: String, distinguished: String? = nil, parent: String? = nil) -> MailFolder {
            MailFolder(id: id, distinguishedID: distinguished, displayName: name, parentID: parent, unreadCount: 0, totalCount: 0, childFolderCount: 0)
        }
        let folders = [
            folder("ROOT", "Top", distinguished: "msgfolderroot"),
            folder("Z", "Zeta", parent: "ROOT"),
            folder("SENT", "Sent", distinguished: "sentitems", parent: "ROOT"),
            folder("JIRA", "Jira", parent: "INBOX"),
            folder("INBOX", "Inbox", distinguished: "inbox", parent: "ROOT"),
            folder("A", "Alpha", parent: "ROOT"),
            folder("A1", "Alpha child", parent: "A"),
        ]
        let ordered = MailFolderTree.ordered(folders)
        XCTAssertEqual(ordered.map(\.id), ["INBOX", "SENT", "JIRA", "A", "A1", "Z"])
        XCTAssertEqual(MailFolderTree.depth(of: folders[6], in: folders), 2)
    }

    func testMenuBarLabelCarriesUnreadMail() {
        XCTAssertEqual(MenuBarLabelView.composedLabel("18m", pendingInvitations: 0, unreadMail: 5), "18m @5")
        XCTAssertEqual(MenuBarLabelView.composedLabel("18m", pendingInvitations: 2, unreadMail: 5), "18m \u{2709}\u{FE0E}2 @5")
        XCTAssertEqual(MenuBarLabelView.composedLabel(nil, pendingInvitations: 0, unreadMail: 3), "@3")
        XCTAssertEqual(MenuBarLabelView.composedLabel("18m", pendingInvitations: 0, unreadMail: 0), "18m")
    }

    func testSettingsRoundTrip() {
        var settings = MailSettings()
        settings.enabled = true
        settings.popoverSectionEnabled = false
        settings.markReadPolicy = .manual
        settings.pollMinutes = 5
        settings.pinnedFolderIDs = ["F1"]
        settings.save(to: defaults)
        XCTAssertEqual(MailSettings.load(from: defaults), settings)
        XCTAssertNil(MailMarkReadPolicy.manual.delay)
        XCTAssertEqual(MailMarkReadPolicy.afterDelay.delay, 3)
    }
}
