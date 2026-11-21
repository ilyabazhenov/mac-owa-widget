import Foundation

/// What changed between two first pages of the inbox (newest conversations first).
///
/// A conversation missing from the newer page counts as gone only if it would still have made
/// that page: when the page is full, anything older than its oldest row may simply have been
/// pushed off it by new mail.
enum InboxChangeDetector {
    static func changes(
        old: [MailConversationSummary],
        new: [MailConversationSummary],
        newPageFull: Bool,
        accountID: UUID
    ) -> [MCPMailChange] {
        let oldByID = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let newIDs = Set(new.map(\.id))
        var changes: [MCPMailChange] = []
        for conversation in new {
            guard let before = oldByID[conversation.id] else {
                changes.append(MCPMailChange(kind: .added, accountID: accountID, conversation: conversation))
                continue
            }
            let fields = changedFields(before, conversation)
            if !fields.isEmpty {
                changes.append(MCPMailChange(kind: .updated, accountID: accountID, conversation: conversation, fields: fields))
            }
        }
        let boundary = newPageFull ? new.compactMap(\.lastDelivery).min() : nil
        for conversation in old where !newIDs.contains(conversation.id) {
            if let boundary, (conversation.lastDelivery ?? .distantPast) <= boundary { continue }
            changes.append(MCPMailChange(kind: .removed, accountID: accountID, conversation: conversation))
        }
        return changes.sorted { ($0.conversation.lastDelivery ?? .distantPast) < ($1.conversation.lastDelivery ?? .distantPast) }
    }

    static func changedFields(_ old: MailConversationSummary, _ new: MailConversationSummary) -> [String] {
        var fields: [String] = []
        if new.messageCount > old.messageCount || (new.lastDelivery ?? .distantPast) > (old.lastDelivery ?? .distantPast) {
            fields.append("new_message")
        } else if new.messageCount < old.messageCount {
            fields.append("message_removed")
        }
        if old.unreadCount > 0, new.unreadCount == 0 { fields.append("read") }
        if old.unreadCount == 0, new.unreadCount > 0 { fields.append("unread") }
        if old.isFlagged != new.isFlagged { fields.append("flag") }
        if Set(old.categories) != Set(new.categories) { fields.append("categories") }
        return fields
    }
}

/// Watches the inbox for `get_changes` while a client keeps asking for mail changes.
///
/// The app's own mail check reads only the inbox count (`GetFolder`) and the unread list, which
/// says nothing about mail read on the phone or a read message filed away. While watching, this
/// reads the first inbox page (`FindConversation`, newest first) whenever the counts moved, and
/// every `fullRefreshInterval` regardless — a move in and a move out cancel out in the counts.
/// The counts come from the app's own check when it ran recently (`countsObserved`); otherwise
/// the watcher reads them itself. Every request goes through `MCPAccessGuard`.
///
/// Watching stops `activeSpan` after the last `get_changes` with mail: a client that went away
/// costs nothing. When it stops, the mail baselines go too, so a client that comes back gets a
/// reset instead of a quiet gap.
@MainActor
final class MCPInboxWatcher {
    enum State: String, Sendable {
        /// Watching, and the first page is in: changes are being recorded.
        case watching
        /// Watching, first page not read yet (just started, or Exchange did not answer).
        case starting
        /// No Exchange mailbox.
        case unavailable
    }

    nonisolated static let activeSpan: TimeInterval = 10 * 60
    nonisolated static let fullRefreshInterval: TimeInterval = 10 * 60
    nonisolated static let defaultInterval: TimeInterval = 2 * 60

    private struct AccountState {
        var page: [MailConversationSummary]?
        var counts: (unread: Int, total: Int)?
        var countsAt: Date?
        var pageAt: Date?
        var isReading = false
    }

    private let calendarService: CalendarService
    private let accessGuard: MCPAccessGuard
    private let feed: MCPChangeFeed
    private let interval: () -> TimeInterval
    private let clock: () -> Date
    private let sleep: @Sendable (TimeInterval) async -> Void
    private var activeUntil: Date?
    private var accounts: [UUID: AccountState] = [:]
    private var loop: Task<Void, Never>?
    /// Off in tests, which drive `check` themselves.
    private let runsLoop: Bool

    init(
        calendarService: CalendarService,
        accessGuard: MCPAccessGuard,
        feed: MCPChangeFeed,
        interval: @escaping () -> TimeInterval = { MCPInboxWatcher.defaultInterval },
        clock: @escaping () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) },
        runsLoop: Bool = true
    ) {
        self.runsLoop = runsLoop
        self.calendarService = calendarService
        self.accessGuard = accessGuard
        self.feed = feed
        self.interval = interval
        self.clock = clock
        self.sleep = sleep
    }

    var isActive: Bool { activeUntil.map { $0 > clock() } ?? false }

    /// Last time each account's inbox was looked at (counts or page).
    func checkedAt(_ accountID: UUID) -> Date? {
        let state = accounts[accountID]
        return [state?.countsAt, state?.pageAt].compactMap { $0 }.max()
    }

    /// A client asked for mail changes: keep (or start) watching.
    func touch() -> State {
        let mailAccounts = calendarService.mailAccounts
        guard !mailAccounts.isEmpty else { return .unavailable }
        activeUntil = clock().addingTimeInterval(Self.activeSpan)
        if runsLoop, loop == nil {
            loop = Task { [weak self] in await self?.run() }
        }
        return mailAccounts.allSatisfy { feed.hasMailBaseline($0.id) } ? .watching : .starting
    }

    /// The app's own inbox check saw these counts: no need to ask again, and a change is worth a
    /// look at the page right away.
    func countsObserved(accountID: UUID, unread: Int, total: Int) {
        guard isActive else { return }
        var state = accounts[accountID] ?? AccountState()
        let moved = state.counts.map { $0.unread != unread || $0.total != total } ?? false
        state.counts = (unread, total)
        state.countsAt = clock()
        accounts[accountID] = state
        if moved, state.page != nil {
            Task { [weak self] in await self?.readPage(accountID) }
        }
    }

    // MARK: - Loop

    private func run() async {
        while isActive {
            for account in calendarService.mailAccounts {
                guard isActive else { break }
                await check(account.id)
            }
            await sleep(interval())
        }
        stop()
    }

    private func stop() {
        loop = nil
        accounts.removeAll()
        feed.dropMailBaselines()
        activeUntil = nil
    }

    /// One pass for one account: counts (unless the app just read them), then the page when
    /// they moved, when there is no page yet, or when the last one is old.
    func check(_ accountID: UUID) async {
        var state = accounts[accountID] ?? AccountState()
        let now = clock()
        var moved = false
        if state.countsAt.map({ now.timeIntervalSince($0) >= interval() * 0.9 }) ?? true {
            guard let counts = await readCounts(accountID) else { return }
            moved = state.counts.map { $0.unread != counts.unread || $0.total != counts.total } ?? false
            state = accounts[accountID] ?? state
            state.counts = counts
            state.countsAt = clock()
            accounts[accountID] = state
        }
        let stale = state.pageAt.map { now.timeIntervalSince($0) >= Self.fullRefreshInterval } ?? true
        if moved || stale || state.page == nil {
            await readPage(accountID)
        }
    }

    private func readCounts(_ accountID: UUID) async -> (unread: Int, total: Int)? {
        guard let folder = try? await request(accountID, context: "mcp.inboxWatch.counts", { provider in
            try await provider.mailFolderCounts([.distinguished(.inbox)]).first
        }) else { return nil }
        return (folder.unreadCount, folder.totalCount)
    }

    func readPage(_ accountID: UUID) async {
        guard accounts[accountID]?.isReading != true else { return }
        accounts[accountID, default: AccountState()].isReading = true
        defer { accounts[accountID]?.isReading = false }
        guard let page = try? await request(accountID, context: "mcp.inboxWatch.page", { provider in
            try await provider.mailConversations(in: .distinguished(.inbox), cursor: .first, filter: .all)
        }) else { return }
        // Stopped while the request was out: recording now would put back a baseline `stop` took.
        guard isActive else { return }
        var state = accounts[accountID] ?? AccountState()
        if let previous = state.page, feed.hasMailBaseline(accountID) {
            let changes = InboxChangeDetector.changes(
                old: previous,
                new: page.conversations,
                newPageFull: page.nextCursor != nil,
                accountID: accountID
            )
            feed.append(changes.map(MCPChange.mail))
        } else {
            feed.markMailBaseline(accountID)
        }
        state.page = page.conversations
        state.pageAt = clock()
        state.isReading = true
        accounts[accountID] = state
    }

    private func request<T: Sendable>(
        _ accountID: UUID,
        context: String,
        _ operation: @Sendable (any MailProvider) async throws -> T
    ) async throws -> T {
        if let denial = accessGuard.permitRequest() { throw MailError.blocked(denial.message) }
        guard let provider = calendarService.mailProvider(accountID: accountID) else { throw MailError.notSupported }
        await accessGuard.acquireSlot()
        defer { accessGuard.releaseSlot() }
        do {
            return try await operation(provider)
        } catch {
            accessGuard.report(error, context: context)
            throw error
        }
    }
}
