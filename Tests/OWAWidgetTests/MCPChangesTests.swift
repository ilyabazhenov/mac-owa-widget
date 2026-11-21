import XCTest
@testable import OWAWidget

/// `get_changes`: the change log, the calendar and inbox comparisons, the inbox watcher and the
/// tool's answer. Fake providers only: no Keychain, no EventKit, no network.
@MainActor
final class MCPChangesTests: XCTestCase {
    private let account = CalendarAccount(id: UUID(), displayName: "Work", serverURL: "https://mail.example.com", email: "user@example.com", accountType: .owa)
    private let base = Date(timeIntervalSince1970: 1_792_000_000)

    private func event(
        _ id: String,
        hours: Double,
        title: String? = nil,
        location: String? = nil,
        response: MeetingResponseType = .accepted,
        organizer: Bool = false,
        cancelled: Bool = false,
        changeKey: String = "ck"
    ) -> CalendarEvent {
        let start = base.addingTimeInterval(hours * 3600)
        return CalendarEvent(
            id: id, title: title ?? "Meeting \(id)", startDate: start, endDate: start.addingTimeInterval(1800),
            location: location, bodyPreview: nil, joinURL: nil, platform: .generic, isAllDay: false,
            organizer: "Grace Miller", accountID: account.id, isCancelled: cancelled, isOrganizer: organizer,
            responseType: response, changeKey: changeKey
        )
    }

    private func window(fromHours: Double, toHours: Double) -> DateInterval {
        DateInterval(start: base.addingTimeInterval(fromHours * 3600), end: base.addingTimeInterval(toHours * 3600))
    }

    private func conversation(
        _ id: String,
        minutes: Double,
        messages: Int = 1,
        unread: Int = 1,
        flagged: Bool = false
    ) -> MailConversationSummary {
        MailConversationSummary(
            id: id, topic: "Subject \(id)", senders: ["Grace Miller"], recipients: [],
            lastDelivery: base.addingTimeInterval(minutes * 60), messageCount: messages, unreadCount: unread, hasAttachments: false,
            importance: .normal, preview: "", itemRefs: [MailItemRef(id: "MSG-\(id)", changeKey: "CK")], categories: [], isFlagged: flagged,
            isProtected: false, instanceKey: nil, parentFolderID: "F-INBOX"
        )
    }

    // MARK: - Feed

    func testCursorWalksTheLogAndResetsHonestly() {
        let feed = MCPChangeFeed(epoch: "e1")
        let first = feed.page(since: nil, limit: 10, includeMail: true)
        XCTAssertEqual(first.reset, .noCursor)
        XCTAssertEqual(first.cursor, "e1-0")

        feed.markCalendarBaseline()
        XCTAssertEqual(feed.page(since: first.cursor, limit: 10, includeMail: true).reset, .calendarResync,
                       "a cursor from before the first sync cannot know what that sync found")
        let afterBaseline = feed.page(since: nil, limit: 10, includeMail: true).cursor

        feed.append([.calendar(MCPCalendarChange(kind: .created, event: event("a", hours: 1)))])
        let page = feed.page(since: afterBaseline, limit: 10, includeMail: true)
        XCTAssertNil(page.reset)
        XCTAssertEqual(page.entries.count, 1)
        XCTAssertEqual(feed.page(since: page.cursor, limit: 10, includeMail: true).entries.count, 0)

        XCTAssertEqual(feed.page(since: "other-1", limit: 10, includeMail: true).reset, .restarted)
        XCTAssertEqual(feed.page(since: "garbage", limit: 10, includeMail: true).reset, .invalid)
        XCTAssertEqual(feed.page(since: "e1-999", limit: 10, includeMail: true).reset, .invalid)
    }

    func testLimitPagesWithHasMore() {
        let feed = MCPChangeFeed(epoch: "e")
        feed.markCalendarBaseline()
        let start = feed.page(since: nil, limit: 1, includeMail: false).cursor
        feed.append((0..<3).map { .calendar(MCPCalendarChange(kind: .created, event: event("\($0)", hours: Double($0)))) })
        let one = feed.page(since: start, limit: 2, includeMail: false)
        XCTAssertEqual(one.entries.count, 2)
        XCTAssertTrue(one.hasMore)
        let two = feed.page(since: one.cursor, limit: 2, includeMail: false)
        XCTAssertEqual(two.entries.map(\.seq), [one.entries[1].seq + 1])
        XCTAssertFalse(two.hasMore)
    }

    func testOverflowAndAgeExpireOldCursors() {
        var now = base
        let feed = MCPChangeFeed(epoch: "e", capacity: 2, clock: { now })
        feed.markCalendarBaseline()
        let start = feed.page(since: nil, limit: 1, includeMail: false).cursor
        feed.append((0..<3).map { .calendar(MCPCalendarChange(kind: .created, event: event("\($0)", hours: 1))) })
        XCTAssertEqual(feed.page(since: start, limit: 10, includeMail: false).reset, .expired)

        let fresh = feed.page(since: nil, limit: 1, includeMail: false).cursor
        XCTAssertNil(feed.page(since: fresh, limit: 10, includeMail: false).reset)
        feed.append([.calendar(MCPCalendarChange(kind: .created, event: event("x", hours: 1)))])
        now = base.addingTimeInterval(MCPChangeFeed.lifetime + 60)
        XCTAssertEqual(feed.page(since: fresh, limit: 10, includeMail: false).reset, .expired)
    }

    func testMailEntriesAndBaselinesOnlyForClientsWithMail() {
        let feed = MCPChangeFeed(epoch: "e")
        feed.markCalendarBaseline()
        let start = feed.page(since: nil, limit: 1, includeMail: true).cursor
        feed.markMailBaseline(account.id)
        XCTAssertNil(feed.page(since: start, limit: 10, includeMail: false).reset, "mail baselines do not concern a client without mail")
        XCTAssertEqual(feed.page(since: start, limit: 10, includeMail: true).reset, .mailResync)

        let cursor = feed.page(since: nil, limit: 1, includeMail: true).cursor
        feed.append([
            .mail(MCPMailChange(kind: .added, accountID: account.id, conversation: conversation("c", minutes: 1))),
            .calendar(MCPCalendarChange(kind: .created, event: event("a", hours: 1))),
        ])
        XCTAssertEqual(feed.page(since: cursor, limit: 10, includeMail: true).entries.count, 2)
        let calendarOnly = feed.page(since: cursor, limit: 10, includeMail: false)
        XCTAssertEqual(calendarOnly.entries.count, 1)
        XCTAssertEqual(calendarOnly.cursor, "e-\(feed.lastSeq)", "skipped mail still moves the cursor")

        feed.dropMailBaselines()
        feed.markMailBaseline(account.id)
        XCTAssertEqual(feed.page(since: calendarOnly.cursor, limit: 10, includeMail: true).reset, .mailResync,
                       "the watcher restarted: what happened in the gap is unknown")
    }

    // MARK: - Calendar comparison

    func testCalendarChangesIgnoreTheSlidingWindow() {
        let oldWindow = window(fromHours: 0, toHours: 100)
        let newWindow = window(fromHours: 10, toHours: 110)
        let old = [event("kept", hours: 50), event("gone", hours: 60), event("aged", hours: 2), event("moved", hours: 70, changeKey: "1")]
        let new = [
            event("kept", hours: 50),
            event("moved", hours: 71, location: "Room 5", changeKey: "2"),
            event("added", hours: 40),
            event("entered", hours: 105),
        ]
        let changes = CalendarChangeDetector.changes(old: old, oldWindow: oldWindow, new: new, newWindow: newWindow)
        XCTAssertEqual(changes.map { "\($0.kind.rawValue):\($0.event.id)" }, ["event_created:added", "event_removed:gone", "event_updated:moved"])
        XCTAssertEqual(changes.last?.fields, ["time", "location"])
    }

    func testCalendarFieldsNameWhatChanged() {
        let before = event("a", hours: 1, response: .notResponded, changeKey: "1")
        XCTAssertEqual(CalendarChangeDetector.changedFields(before, event("a", hours: 1, response: .accepted, changeKey: "2")), ["my_response"])
        XCTAssertEqual(CalendarChangeDetector.changedFields(before, event("a", hours: 1, response: .notResponded, cancelled: true, changeKey: "2")), ["cancelled"])
        XCTAssertEqual(CalendarChangeDetector.changedFields(before, event("a", hours: 1, response: .notResponded, changeKey: "2")), ["other"],
                       "a new ChangeKey with nothing visible: usually an attendee's answer")
        XCTAssertEqual(CalendarChangeDetector.changedFields(before, before), [])
    }

    private actor MutableProvider: CalendarProvider {
        nonisolated let account: CalendarAccount
        var events: [CalendarEvent] = []
        init(account: CalendarAccount) { self.account = account }
        func set(_ events: [CalendarEvent]) { self.events = events }
        func fetchEvents(from start: Date, to end: Date) async throws -> [CalendarEvent] { events }
        func validateCredentials() async throws {}
    }

    func testSyncsFeedTheChangeLog() async {
        let provider = MutableProvider(account: account)
        let service = CalendarService(
            providers: [provider],
            notificationService: SilentNotificationService(),
            customMeetingReminders: SilentMeetingReminderController(),
            loadPersistedAccounts: false,
            startBackgroundTasks: false
        )
        let soon = Date().timeIntervalSince(base) / 3600 + 2
        await provider.set([event("a", hours: soon)])
        await service.performSyncForTests()
        XCTAssertTrue(service.changeFeed.hasCalendarBaseline)
        let cursor = service.changeFeed.page(since: nil, limit: 10, includeMail: false).cursor

        service.applyResponseTypeForTests(.declined, to: "a")
        await provider.set([event("a", hours: soon, response: .declined, changeKey: "2"), event("b", hours: soon + 1)])
        await service.performSyncForTests()
        let page = service.changeFeed.page(since: cursor, limit: 10, includeMail: false)
        let kinds = page.entries.compactMap { entry -> String? in
            guard case .calendar(let change) = entry.change else { return nil }
            return "\(change.kind.rawValue):\(change.event.id):\(change.fields.joined(separator: ","))"
        }
        XCTAssertEqual(kinds, ["event_updated:a:my_response", "event_created:b:"],
                       "compared with the last fetch, so an answer given in the app is still a change")
    }

    // MARK: - Inbox comparison

    func testInboxChanges() {
        let old = [conversation("new-msg", minutes: 50), conversation("read", minutes: 40), conversation("filed", minutes: 30, unread: 0), conversation("old", minutes: 1)]
        let new = [
            conversation("fresh", minutes: 60),
            conversation("new-msg", minutes: 55, messages: 2),
            conversation("read", minutes: 40, unread: 0),
            conversation("flag", minutes: 20, unread: 0, flagged: true),
        ]
        let full = InboxChangeDetector.changes(old: old, new: new, newPageFull: true, accountID: account.id)
        XCTAssertEqual(full.map { "\($0.kind.rawValue):\($0.conversation.id):\($0.fields.joined(separator: ","))" }, [
            "mail_added:flag:",
            "mail_removed:filed:",
            "mail_updated:read:read",
            "mail_updated:new-msg:new_message",
            "mail_added:fresh:",
        ], "`old` fell off a full page by age: not a removal")
        let short = InboxChangeDetector.changes(old: old, new: new, newPageFull: false, accountID: account.id)
        XCTAssertTrue(short.contains { $0.kind == .removed && $0.conversation.id == "old" }, "the whole inbox fits: missing means gone")
    }

    // MARK: - Watcher and tool

    private actor InboxProvider: CalendarProvider, MailProvider {
        nonisolated let account: CalendarAccount
        var page: [MailConversationSummary] = []
        var counts = (unread: 1, total: 1)
        private(set) var calls: [String] = []
        init(account: CalendarAccount) { self.account = account }
        func set(page: [MailConversationSummary], unread: Int, total: Int) {
            self.page = page
            counts = (unread, total)
        }

        func fetchEvents(from start: Date, to end: Date) async throws -> [CalendarEvent] { [] }
        func validateCredentials() async throws {}
        func mailFolders() async throws -> [MailFolder] { [] }
        func mailFolderCounts(_ folders: [MailFolderRef]) async throws -> [MailFolder] {
            calls.append("counts")
            return [MailFolder(id: "F-INBOX", distinguishedID: "inbox", displayName: "Inbox", parentID: nil, unreadCount: counts.unread, totalCount: counts.total, childFolderCount: 0)]
        }
        func mailConversations(in folder: MailFolderRef, cursor: MailListCursor, filter: MailListFilter) async throws -> MailConversationPage {
            calls.append("page:\(filter.rawValue)")
            return MailConversationPage(conversations: page, totalInView: page.count, nextCursor: nil)
        }
        func mailItems(in folder: MailFolderRef, cursor: MailListCursor, filter: MailListFilter, count: Int) async throws -> MailItemPage {
            MailItemPage(items: [], totalInView: 0, nextCursor: nil)
        }
        func mailThread(conversationID: String, ignoringFolders: [String]) async throws -> MailThread { throw MailError.notFound }
        func mailMessage(_ ref: MailItemRef) async throws -> MailMessage { throw MailError.notFound }
        func mailAttachment(id: String, maxBytes: Int) async throws -> Data { Data() }
        func mailUpdate(_ targets: [MailItemTarget], _ update: MailItemUpdate) async throws -> [MailItemRef] { [] }
        func mailMove(_ refs: [MailItemRef], to folder: MailFolderRef) async throws -> [MailItemRef] { [] }
        func mailSearch(_ query: MailSearchQuery, offset: Int, count: Int) async throws -> MailSearchPage { throw MailError.notSupported }
        func mailEndSearch() async {}
        func mailSend(_ outgoing: MailOutgoing) async throws -> MailItemRef? { nil }
        func mailDraftForReview(_ ref: MailItemRef) async throws -> MailMessage { throw MailError.notSupported }
        func mailSendDraft(_ ref: MailItemRef) async throws {}
        func mailDeleteDraft(_ ref: MailItemRef) async throws {}
    }

    private func makeService(_ provider: InboxProvider) -> CalendarService {
        let service = CalendarService(
            providers: [provider],
            notificationService: SilentNotificationService(),
            customMeetingReminders: SilentMeetingReminderController(),
            loadPersistedAccounts: false,
            startBackgroundTasks: false
        )
        service.replaceAccountsForTests([account])
        return service
    }

    func testWatcherReadsThePageOnlyWhenCountsMoveOrItGetsOld() async {
        var now = base
        let provider = InboxProvider(account: account)
        let service = makeService(provider)
        let watcher = MCPInboxWatcher(
            calendarService: service,
            accessGuard: MCPAccessGuard(calendarService: service, clock: { now }),
            feed: service.changeFeed,
            clock: { now },
            runsLoop: false
        )
        await provider.set(page: [conversation("a", minutes: 1)], unread: 1, total: 1)
        XCTAssertEqual(watcher.touch(), .starting)
        await watcher.check(account.id)
        XCTAssertTrue(service.changeFeed.hasMailBaseline(account.id))
        let cursor = service.changeFeed.page(since: nil, limit: 10, includeMail: true).cursor

        now = now.addingTimeInterval(130)
        await watcher.check(account.id)
        var calls = await provider.calls
        XCTAssertEqual(calls.filter { $0 == "page:All" }.count, 1, "counts unchanged: no page")

        await provider.set(page: [conversation("a", minutes: 1, unread: 0)], unread: 0, total: 1)
        now = now.addingTimeInterval(130)
        await watcher.check(account.id)
        let page = service.changeFeed.page(since: cursor, limit: 10, includeMail: true)
        XCTAssertEqual(page.entries.count, 1)
        guard case .mail(let change)? = page.entries.first?.change else { return XCTFail("expected a mail change") }
        XCTAssertEqual(change.fields, ["read"])

        // The app's own check saw the counts: the watcher does not ask for them again.
        now = now.addingTimeInterval(130)
        watcher.countsObserved(accountID: account.id, unread: 0, total: 1)
        await watcher.check(account.id)
        calls = await provider.calls
        XCTAssertEqual(calls.filter { $0 == "counts" }.count, 3)

        now = now.addingTimeInterval(MCPInboxWatcher.fullRefreshInterval)
        await watcher.check(account.id)
        calls = await provider.calls
        XCTAssertEqual(calls.filter { $0 == "page:All" }.count, 3, "an old page is read again even with quiet counts")
    }

    func testToolAnswersWithCursorAndKeepsMailForAllowedClients() async throws {
        let provider = InboxProvider(account: account)
        let service = makeService(provider)
        let accessGuard = MCPAccessGuard(calendarService: service)
        let calendarTools = MCPCalendarTools(calendarService: service, timeZone: { TimeZone(identifier: "Europe/Moscow")! })
        let mailTools = MCPMailTools(calendarService: service, accessGuard: accessGuard, isEnabled: { true })
        let watcher = MCPInboxWatcher(calendarService: service, accessGuard: accessGuard, feed: service.changeFeed, runsLoop: false)
        let tools = MCPChangeTools(calendarService: service, calendarTools: calendarTools, mailTools: mailTools, watcher: watcher, isEnabled: { true })

        service.changeFeed.markCalendarBaseline()
        let first = try XCTUnwrap(tools.call(arguments: [:], mail: .notAllowed).structured)
        XCTAssertEqual(first["reset"], true)
        XCTAssertEqual(first["reset_reason"]?.stringValue, "no_cursor")
        XCTAssertEqual(first["mail"]?["state"]?.stringValue, "not_allowed")
        XCTAssertEqual(first["calendar"]?["state"]?.stringValue, "watching")
        let cursor = try XCTUnwrap(first["cursor"]?.stringValue)

        let created = event("x", hours: 3, response: .notResponded)
        service.changeFeed.append([
            .calendar(MCPCalendarChange(kind: .created, event: created)),
            .mail(MCPMailChange(kind: .added, accountID: account.id, conversation: conversation("m", minutes: 1))),
        ])
        let second = try XCTUnwrap(tools.call(arguments: ["since_cursor": .string(cursor)], mail: .notAllowed).structured)
        let changes = try XCTUnwrap(second["changes"]?.arrayValue)
        XCTAssertEqual(changes.count, 1, "no mail for a client without mail consent")
        XCTAssertEqual(changes.first?["type"]?.stringValue, "event_created")
        XCTAssertEqual(changes.first?["event_id"]?.stringValue, MCPEventID.short("x"))
        XCTAssertEqual(changes.first?["needs_response"], true)

        let withMail = try XCTUnwrap(tools.call(arguments: ["since_cursor": .string(cursor)], mail: .allowed).structured)
        XCTAssertEqual(withMail["mail"]?["state"]?.stringValue, "starting", "the watcher has not looked yet")
        XCTAssertEqual(withMail["changes"]?.arrayValue?.count, 1)
        XCTAssertTrue(watcher.isActive)

        XCTAssertTrue(tools.call(arguments: ["limit": 0], mail: .allowed).isError)
        XCTAssertTrue(tools.call(arguments: ["since_cursor": 5], mail: .allowed).isError)
        let off = MCPChangeTools(calendarService: service, calendarTools: calendarTools, mailTools: mailTools, watcher: watcher, isEnabled: { false })
        XCTAssertTrue(off.call(arguments: [:], mail: .allowed).isError)
    }
}
