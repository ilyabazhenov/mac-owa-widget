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
    private(set) var updateKinds: [MailItemKind] = []

    init(account: CalendarAccount) { self.account = account }

    func setUnread(_ value: Int) { unread = value }
    func setFailure(_ error: Error?) { failure = error }
    func setConversations(_ value: [MailConversationSummary]) { conversations = value }
    /// Pages of this size, the cursor being the offset; `nil` gives everything at once.
    var conversationPageSize: Int?
    func setConversationPageSize(_ value: Int?) { conversationPageSize = value }
    func setThread(_ thread: MailThread) { threads[thread.id] = thread }
    func setFolders(_ value: [MailFolder]) { folderList = value }
    func setSearchPages(_ value: [MailSearchPage]) { searchPages = value }
    /// Delays of the next `mailConversations` calls, one per call in order: lets an earlier
    /// request answer after a later one.
    var conversationDelays: [UInt64] = []
    func setConversationDelays(_ value: [UInt64]) { conversationDelays = value }

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
        // What the mailbox held when the request came in, however late the answer.
        var page = conversations
        var next: MailListCursor?
        if let size = conversationPageSize {
            let start = if case .after(let key) = cursor { Int(key) ?? 0 } else { 0 }
            page = Array(conversations.dropFirst(start).prefix(size))
            if start + size < conversations.count { next = .after(instanceKey: String(start + size)) }
        }
        if !conversationDelays.isEmpty { try await Task.sleep(nanoseconds: conversationDelays.removeFirst()) }
        return MailConversationPage(conversations: page, totalInView: conversations.count, nextCursor: next)
    }

    var unreadItems: [MailListItem] = []
    func setUnreadItems(_ value: [MailListItem]) { unreadItems = value }

    /// Pages of this size for `mailItems`, the cursor being the offset; `nil` always answers the
    /// first `count` (what marking everything read relies on).
    var itemPageSize: Int?
    func setItemPageSize(_ value: Int?) { itemPageSize = value }
    /// The cursors `mailItems` was asked with, in order.
    private(set) var itemCursors: [MailListCursor] = []

    func mailItems(in folder: MailFolderRef, cursor: MailListCursor, filter: MailListFilter, count: Int) async throws -> MailItemPage {
        try record("items")
        itemCursors.append(cursor)
        if let size = itemPageSize {
            let start = if case .after(let key) = cursor { Int(key) ?? 0 } else { 0 }
            let page = Array(unreadItems.dropFirst(start).prefix(size))
            let next: MailListCursor? = start + size < unreadItems.count ? .after(instanceKey: String(start + size)) : nil
            return MailItemPage(items: page, totalInView: unreadItems.count, nextCursor: next)
        }
        let page = Array(unreadItems.prefix(count))
        return MailItemPage(items: page, totalInView: unreadItems.count, nextCursor: unreadItems.count > count ? .after(instanceKey: "next") : nil)
    }

    private(set) var lastIgnoredFolders: [String]?
    func mailThread(conversationID: String, ignoringFolders: [String]) async throws -> MailThread {
        try record("thread")
        lastIgnoredFolders = ignoringFolders
        guard let thread = threads[conversationID] else { throw MailError.notFound }
        return thread
    }

    /// What `mailMessage` answers for an item instead of its copy in a thread: a conversation
    /// can leave out what a single item read returns (inline attachments).
    var fullMessages: [String: MailMessage] = [:]
    func setFullMessage(_ message: MailMessage) { fullMessages[message.ref.id] = message }

    func mailMessage(_ ref: MailItemRef) async throws -> MailMessage {
        try record("message")
        if let full = fullMessages[ref.id] { return full }
        guard let message = threads.values.flatMap(\.messages).first(where: { $0.ref.id == ref.id }) else { throw MailError.notFound }
        return message
    }

    func mailAttachment(id: String, maxBytes: Int) async throws -> Data { try record("attachment"); return Data("x".utf8) }

    /// Updates after this many succeed are refused: lets a later change of a run fail alone.
    var updatesBeforeFailure: Int?
    func setUpdatesBeforeFailure(_ value: Int?) { updatesBeforeFailure = value }

    func mailUpdate(_ targets: [MailItemTarget], _ update: MailItemUpdate) async throws -> [MailItemRef] {
        try record("update")
        if let limit = updatesBeforeFailure, updates.count >= limit { throw URLError(.timedOut) }
        let refs = targets.map(\.ref)
        for target in targets { updateKinds.append(target.kind) }
        for ref in refs { updates.append((ref, update)) }
        if case .isRead(true) = update {
            let marked = Set(refs.map(\.id))
            unreadItems.removeAll { marked.contains($0.ref.id) }
        }
        return refs.map { MailItemRef(id: $0.id, changeKey: ($0.changeKey ?? "") + "+") }
    }
    var updateCount: Int { updates.count }

    /// Every move, in order: which items went where.
    private(set) var moves: [(ids: [String], folder: MailFolderRef)] = []
    /// The server answers a move without the items' new ids (some do): nothing to undo with.
    var moveReturnsIDs = true
    func setMoveReturnsIDs(_ value: Bool) { moveReturnsIDs = value }

    func mailMove(_ refs: [MailItemRef], to folder: MailFolderRef) async throws -> [MailItemRef] {
        try record("move")
        moves.append((refs.map(\.id), folder))
        return moveReturnsIDs ? refs.map { MailItemRef(id: $0.id + "-moved", changeKey: nil) } : []
    }

    func mailSearch(_ query: MailSearchQuery, offset: Int, count: Int) async throws -> MailSearchPage {
        try record("search")
        return searchPages.isEmpty ? MailSearchPage(conversations: [], moreAvailable: false, searchTerms: [], refiners: [], offset: offset) : searchPages.removeFirst()
    }

    func mailEndSearch() async { calls.append("endSearch") }

    func mailSend(_ outgoing: MailOutgoing) async throws -> MailItemRef? {
        try record("send")
        if outgoing.send {
            sent.append(outgoing)
            return nil
        }
        drafts.append(outgoing)
        let id = "DRAFT-\(drafts.count)"
        reviewDrafts[id] = outgoing
        return MailItemRef(id: id, changeKey: "CK-DRAFT")
    }

    // Drafts: what Exchange holds and would send.
    private(set) var drafts: [MailOutgoing] = []
    private(set) var reviewDrafts: [String: MailOutgoing] = [:]
    private(set) var deletedDrafts: [String] = []
    /// Recipients the server adds on its own (a Reply-To, people removed from a reply-all).
    var draftExtraRecipients: [MailAddress] = []
    var draftHiddenRecipients = 0
    var sendDraftError: Error?
    func setDraftExtraRecipients(_ value: [MailAddress]) { draftExtraRecipients = value }
    func setDraftHiddenRecipients(_ value: Int) { draftHiddenRecipients = value }
    func setSendDraftError(_ value: Error?) { sendDraftError = value }

    func mailDraftForReview(_ ref: MailItemRef) async throws -> MailMessage {
        try record("draftReview")
        guard let outgoing = reviewDrafts[ref.id] else { throw MailError.notFound }
        return MailMessage(
            ref: MailItemRef(id: ref.id, changeKey: "CK-DRAFT-2"), conversationID: nil, parentFolderID: "DRAFTS", kind: .note,
            subject: outgoing.subject, from: nil,
            to: outgoing.to.map { MailAddress(name: $0, email: $0) } + draftExtraRecipients,
            cc: outgoing.cc.map { MailAddress(name: $0, email: $0) }, bcc: [],
            hiddenRecipientCount: draftHiddenRecipients, received: nil, sent: nil, isRead: true, isDraft: true, importance: .normal,
            bodyHTML: outgoing.body.plainText, preview: "", attachments: [], categories: [], isFlagged: false,
            actions: [], meeting: nil, internetMessageID: nil
        )
    }

    func mailSendDraft(_ ref: MailItemRef) async throws {
        try record("sendDraft")
        if let sendDraftError { throw sendDraftError }
        guard var outgoing = reviewDrafts[ref.id] else { throw MailError.notFound }
        outgoing.send = true
        sent.append(outgoing)
        reviewDrafts[ref.id] = nil
    }

    func mailDeleteDraft(_ ref: MailItemRef) async throws {
        try record("deleteDraft")
        deletedDrafts.append(ref.id)
        reviewDrafts[ref.id] = nil
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
    var people: [ResolvedAttendee] = []
    func findMailPeople(query: String, accountID: UUID) async throws -> [ResolvedAttendee] { people }
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

    static func message(_ id: String, conversation: String, isRead: Bool = false, kind: MailItemKind = .note) -> MailMessage {
        MailMessage(
            ref: MailItemRef(id: id, changeKey: "CK"), conversationID: conversation, parentFolderID: "INBOX", kind: kind,
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
        let prepared = try await service.prepareSend(outgoing)
        try await service.sendPrepared(prepared)
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
