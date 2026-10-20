import Combine
import Foundation
import UserNotifications
import os.log

/// What `MailService` needs from the rest of the app: the accounts with mail, their providers
/// and the shared circuit breaker. `CalendarService` is the real one; tests pass a fake.
@MainActor
protocol MailBackend: AnyObject {
    var mailAccounts: [CalendarAccount] { get }
    func mailProvider(accountID: UUID) -> (any MailProvider)?
    /// True while sync is suspended pending the user (wrong password, untrusted certificate):
    /// mail makes no requests then, or it would walk the account into an AD lockout.
    var isMailBlocked: Bool { get }
    func reportMailFailure(_ error: Error, context: String)
    /// The user's own address in that account, looked up in the address book.
    func ownMailAddress(accountID: UUID) async -> String?
    /// The Exchange address book, for recipient suggestions.
    func findMailPeople(query: String, accountID: UUID) async throws -> [ResolvedAttendee]
    /// Answers a meeting request found in mail through the calendar; `false` when that meeting is
    /// not in the synced calendar (outside the window, or already gone).
    func respondToMailMeeting(calendarItemID: String, action: MeetingResponseAction) async throws -> Bool
    /// The response already given to that meeting, when the calendar knows it.
    func mailMeetingResponse(calendarItemID: String) -> MeetingResponseType?
    /// Lowercased names of the people the user deals with now: today's meeting participants and
    /// watched colleagues. Mail from them counts as important.
    var mailVIPNames: Set<String> { get }
    /// When the synced calendar has a meeting with this title (an invitation in the list says
    /// nothing about its time): the upcoming one first.
    func mailMeetingInterval(topic: String) -> DateInterval?
}

extension MailBackend {
    func mailMeetingInterval(topic: String) -> DateInterval? { nil }
}

extension CalendarService: MailBackend {
    var isMailBlocked: Bool { syncStatus.blocksSync }

    func reportMailFailure(_ error: Error, context: String) {
        reportExternalRequestFailure(error, context: context)
    }

    func ownMailAddress(accountID: UUID) async -> String? {
        guard !syncStatus.blocksSync else { return nil }
        return try? await ownEmail(accountID: accountID)
    }

    func findMailPeople(query: String, accountID: UUID) async throws -> [ResolvedAttendee] {
        guard !syncStatus.blocksSync else { return [] }
        return try await findPeople(query: query, accountID: accountID)
    }

    func respondToMailMeeting(calendarItemID: String, action: MeetingResponseAction) async throws -> Bool {
        guard let event = events.first(where: { $0.id == calendarItemID }) else { return false }
        try await respondToMeeting(event, action: action)
        return true
    }

    func mailMeetingResponse(calendarItemID: String) -> MeetingResponseType? {
        events.first { $0.id == calendarItemID }?.responseType
    }

    var mailVIPNames: Set<String> {
        let calendar = AppTimeZone.calendar
        let now = Date()
        var names = Set<String>()
        for event in events where calendar.isDate(event.startDate, inSameDayAs: now) && !event.isAllDay {
            if let organizer = event.organizer { names.insert(MailVIP.normalized(organizer)) }
            for attendee in event.attendees { names.insert(MailVIP.normalized(attendee)) }
        }
        for colleague in WatchedColleaguesStore.load() { names.insert(MailVIP.normalized(colleague.displayName)) }
        names.remove("")
        return names
    }

    func mailMeetingInterval(topic: String) -> DateInterval? {
        let wanted = MailVIP.normalized(topic)
        guard !wanted.isEmpty else { return nil }
        let matches = events.filter { MailVIP.normalized($0.title) == wanted && !$0.isAllDay && $0.endDate > $0.startDate }
        let now = Date()
        let event = matches.filter { $0.endDate > now }.min { $0.startDate < $1.startDate } ?? matches.max { $0.startDate < $1.startDate }
        return event.map { DateInterval(start: $0.startDate, end: $0.endDate) }
    }
}

enum MailVIP {
    static func normalized(_ name: String) -> String {
        name.lowercased().replacingOccurrences(of: "ё", with: "е").split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Matches "Иванов Пётр" against "Пётр Иванов" too: same words in any order.
    static func matches(_ sender: String, in names: Set<String>) -> Bool {
        let normalized = normalized(sender)
        guard !normalized.isEmpty else { return false }
        if names.contains(normalized) { return true }
        let words = Set(normalized.split(separator: " "))
        guard words.count >= 2 else { return false }
        // A sender shown as "Иванов Пётр Сергеевич" is the colleague saved as "Пётр Иванов".
        return names.contains { name in
            let other = Set(name.split(separator: " "))
            return other.count >= 2 && (other.isSubset(of: words) || words.isSubset(of: other))
        }
    }
}

/// Cancelled requests (a view went away, the user moved on) are not failures to report.
enum MailCancellation {
    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let url = error as? URLError, url.code == .cancelled { return true }
        let ns = error as NSError
        return ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled
    }
}

/// A request to show a conversation in the mail window (from the popover or a notification).
struct MailOpenRequest: Equatable {
    let conversationID: String
    /// The folder to show around it (the inbox panel's), when not the window's own.
    var folder: MailFolderRef? = nil
    let token = UUID()
}

/// What the compose window starts from.
struct MailComposeRequest: Identifiable, Equatable {
    let id = UUID()
    var kind: MailOutgoing.Kind
    var original: MailMessage?
    var to: [String]
    var cc: [String]
    var subject: String
    var body: String
    /// The original as the reader shows it (`MailHTMLDocument.document`), for a reply or a
    /// forward opened from the mail window; `nil` shows its preview text instead.
    var originalDocument: String? = nil

    /// A new message from a `mailto:` link (RFC 6068): the addresses before `?`, then `to`, `cc`,
    /// `subject` and `body` from the query. Approval portals put the request's number in the
    /// subject or the body, so neither may be lost. `+` stays a plus (RFC 6068), and `bcc` is
    /// dropped: the compose window has no hidden copy, and putting it in `cc` would show it.
    static func mailto(_ url: URL) -> MailComposeRequest? {
        let text = url.absoluteString
        guard text.lowercased().hasPrefix("mailto:") else { return nil }
        let rest = text.dropFirst("mailto:".count)
        let parts = rest.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        var to = addresses(parts.first.map(String.init) ?? "")
        var cc: [String] = []
        var subject = ""
        var body = ""
        for pair in (parts.count > 1 ? parts[1] : "").split(separator: "&") {
            let field = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let value = field.count > 1 ? String(field[1]) : ""
            switch decoded(String(field[0])).lowercased() {
            case "to": to += addresses(value)
            case "cc": cc += addresses(value)
            case "subject" where subject.isEmpty: subject = decoded(value)
            case "body" where body.isEmpty:
                body = decoded(value).replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            default: break
            }
        }
        return MailComposeRequest(kind: .new, original: nil, to: unique(to), cc: unique(cc), subject: subject, body: body)
    }

    private static func decoded(_ text: String) -> String {
        text.removingPercentEncoding ?? text
    }

    /// Comma-separated addresses, each possibly written as `Name <address>`.
    private static func addresses(_ encoded: String) -> [String] {
        decoded(encoded).split(separator: ",").compactMap { part in
            var address = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if let open = address.lastIndex(of: "<"), let close = address.lastIndex(of: ">"), open < close {
                address = address[address.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
            }
            return address.isEmpty ? nil : address
        }
    }

    private static func unique(_ addresses: [String]) -> [String] {
        var seen = Set<String>()
        return addresses.filter { seen.insert($0.lowercased()).inserted }
    }
}

enum MailLoadState: Equatable {
    case idle
    case loading
    case failed(String)
    case blocked
}

/// The app's mail: settings, the periodic unread check, a small in-memory cache of threads and
/// every request the mail window makes. Nothing is written to disk.
@MainActor
final class MailService: ObservableObject {
    static let threadCacheLimit = 100
    /// Threads kept after the mail window closes, then dropped.
    static let cacheLingerAfterClose: TimeInterval = 10 * 60
    static let popoverUnreadLimit = 5
    static let inlineImageLimit = 5 * 1024 * 1024
    nonisolated static let notificationIdentifierPrefix = "owawidget-mail."
    static let notificationsPerCheck = 3
    static let bulkPageSize = 50
    static let markAllReadLimit = 1_000
    static let blockedMessage = "Sync is paused until the password or the server certificate is confirmed in OWA Widget; mail makes no requests meanwhile."

    @Published private(set) var settings: MailSettings
    @Published private(set) var folders: [MailFolder] = []
    @Published private(set) var inboxUnreadCount: Int?
    @Published private(set) var latestUnread: [MailConversationSummary] = []
    /// Unread conversations from people (not from systems), from the first unread page.
    @Published private(set) var peopleUnread: [MailConversationSummary] = []
    /// The size of the unread page `peopleUnread` was cut from: the count is "N+" past it.
    @Published private(set) var unreadPageWasFull = false
    /// The folder the panel beside the popover shows (the inbox unless the user picked another),
    /// remembered between launches.
    @Published private(set) var panelFolder: MailFolderRef = .distinguished(.inbox)
    /// That folder's newest conversations, as the folder lists them. Loaded only once the panel
    /// has been shown (`refreshPanelList`).
    @Published private(set) var panelList: [MailConversationSummary] = []
    /// Where the panel's next page starts; `nil` when the folder has nothing more.
    @Published private(set) var panelNextCursor: MailListCursor?
    /// The next page is on its way (scrolling to the bottom asked for it).
    @Published private(set) var isLoadingMorePanelList = false
    /// When the panel's folder last loaded fine: a failed load leaves it, so the next look retries.
    @Published private(set) var panelListLoaded: Date?
    /// The panel has been shown since the account was set up: new mail then refreshes its list
    /// (while the panel stays turned on).
    private var panelWanted = false
    /// Only the newest panel request writes the list: an older one that answers later would put
    /// back an older page.
    private var panelListGeneration = 0
    /// A panel list request is on its way (a folder switch can overlap a refresh).
    @Published private(set) var isLoadingPanelList = false
    private var panelLoadsInFlight = 0 {
        didSet { isLoadingPanelList = panelLoadsInFlight > 0 }
    }
    /// The last request for the panel's folder failed: an empty list is not an empty folder.
    @Published private(set) var panelListFailed = false
    /// A request for the panel's folder has come back (fine or not): until then an empty list
    /// means "loading", not "empty folder".
    var panelListAnswered: Bool { panelListLoaded != nil || panelListFailed }
    static let panelFolderKey = "mailPanelFolder"
    /// The account the remembered folder belongs to: a folder id means nothing in another mailbox.
    static let panelFolderAccountKey = "mailPanelFolderAccount"
    @Published private(set) var lastChecked: Date?
    @Published private(set) var checkState: MailLoadState = .idle
    @Published var openRequest: MailOpenRequest?
    @Published var composeRequest: MailComposeRequest?
    /// Every successful change to a message, so open lists can update the row in place.
    @Published private(set) var changeGeneration = 0
    /// The user's own address, once looked up: excluded from reply-all, and its domain tells
    /// external recipients apart.
    @Published private(set) var ownAddress: String?

    private weak var backend: (any MailBackend)?
    private let defaults: UserDefaults
    private let log = Logger(subsystem: "com.owawidget", category: "MailService")
    private var pollTimer: Timer?
    private var threadCache: [String: MailThread] = [:]
    private var threadOrder: [String] = []
    private var cacheClearTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []
    private var isChecking = false
    private var isResolvingOwnAddress = false
    private var lastCountsRefresh: Date?
    private(set) var isWindowOpen = false
    /// The inbox's id, learned from the unread check or the folder list.
    private var inboxFolderID: String?
    /// Unread conversations already seen, so only new ones notify. `nil` until the first check,
    /// which records silently: everything unread at launch would otherwise notify at once.
    private var seenUnreadIDs: Set<String>?
    /// Posts a system notification; replaced in tests. The second argument is the "external"
    /// label when the sender is outside the organization, `nil` otherwise.
    var notifier: (MailConversationSummary, String?) -> Void = { MailService.postNotification($0, externalLabel: $1) }
    /// For the words notifications carry; set by the app.
    weak var localization: LocalizationService?

    init(backend: (any MailBackend)? = nil, defaults: UserDefaults = .standard) {
        self.backend = backend
        self.defaults = defaults
        self.settings = MailSettings.load(from: defaults)
        self.panelFolder = Self.folderRef(storageValue: defaults.string(forKey: Self.panelFolderKey)) ?? .distinguished(.inbox)
    }

    /// The app's instance, for views outside the mail window's environment (the meeting card).
    private(set) weak static var current: MailService?

    /// Wires the service to the calendar's accounts and providers. Called once at launch.
    func attach(_ calendarService: CalendarService) {
        Self.current = self
        guard backend == nil else { return }
        backend = calendarService
        calendarService.$providerGeneration
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor in self?.providersChanged() }
            }
            .store(in: &cancellables)
        restartPolling()
    }

    // MARK: - Settings

    func updateSettings(_ change: (inout MailSettings) -> Void) {
        var updated = settings
        change(&updated)
        guard updated != settings else { return }
        let wasEnabled = settings.enabled
        let oldInterval = settings.pollMinutes
        let oldAccount = settings.accountID
        settings = updated
        updated.save(to: defaults)
        if oldAccount != updated.accountID { providersChanged() }
        if wasEnabled != updated.enabled || oldInterval != updated.pollMinutes { restartPolling() }
        if !updated.enabled { clearState() }
    }

    var mailAccounts: [CalendarAccount] { backend?.mailAccounts ?? [] }

    /// The account the mail window and the unread check use.
    var account: CalendarAccount? {
        let accounts = mailAccounts
        if let id = settings.accountID, let chosen = accounts.first(where: { $0.id == id }) { return chosen }
        return accounts.first
    }

    var isAvailable: Bool { settings.enabled && account != nil }

    /// The count for the menu bar label; zero while the badge is off.
    /// The count for the menu bar label; zero while the badge is off. With "people only" it counts
    /// the people's conversations on the first unread page (a robot's 400 messages are not news).
    var menuBarUnreadCount: Int {
        guard isAvailable, settings.menuBarBadgeEnabled else { return 0 }
        return settings.peopleOnly ? peopleUnread.count : (inboxUnreadCount ?? 0)
    }

    /// What the popover lists: people's unread first-class, or every unread conversation.
    var popoverUnread: [MailConversationSummary] {
        Array((settings.peopleOnly ? peopleUnread : latestUnread).prefix(Self.popoverUnreadLimit))
    }

    /// The number the popover strip shows next to "Mail".
    var popoverUnreadCount: Int? {
        settings.peopleOnly ? peopleUnread.count : inboxUnreadCount
    }

    var showsPopoverSection: Bool { isAvailable && settings.popoverSectionEnabled }

    var isBlocked: Bool { backend?.isMailBlocked ?? false }

    // MARK: - Unread check

    private func restartPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        guard settings.enabled else { return }
        let interval = TimeInterval(settings.pollMinutes * 60)
        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor [weak self] in await self?.checkInbox() }
        }
        Task { await checkInbox() }
    }

    /// Called when the popover opens: a check older than half a minute is refreshed.
    func popoverDidAppear() {
        guard isAvailable else { return }
        if let lastChecked, Date().timeIntervalSince(lastChecked) < 30 { return }
        Task { await checkInbox() }
    }

    /// One `GetFolder` for the inbox count, plus the first unread page when the count changed
    /// and the popover shows the list.
    func checkInbox() async {
        guard isAvailable, !isChecking, let account, let provider = backend?.mailProvider(accountID: account.id) else { return }
        guard !isBlocked else {
            checkState = .blocked
            return
        }
        isChecking = true
        defer { isChecking = false }
        do {
            let counts = try await provider.mailFolderCounts([.distinguished(.inbox)])
            let unread = counts.first?.unreadCount ?? 0
            if let id = counts.first?.id { inboxFolderID = id }
            let changed = unread != inboxUnreadCount
            inboxUnreadCount = unread
            lastChecked = Date()
            checkState = .idle
            if ownAddress == nil { Task { await resolveOwnAddress() } }
            let needsList = settings.popoverSectionEnabled || settings.menuBarBadgeEnabled || settings.notifyMode != .off
            if needsList, changed || (unread > 0 && latestUnread.isEmpty) || seenUnreadIDs == nil {
                if unread == 0 {
                    applyUnreadPage([], full: false)
                } else {
                    let page = try await provider.mailConversations(in: .distinguished(.inbox), cursor: .first, filter: .unread)
                    applyUnreadPage(page.conversations.filter(\.isUnread), full: page.nextCursor != nil)
                }
            }
            // New mail (or mail read elsewhere): the inbox panel, once it has been shown, follows.
            if changed, panelWanted, PopoverInboxPanelStore.isShown(in: defaults), panelFolder == .distinguished(.inbox) {
                await refreshPanelList(minInterval: 0)
            }
        } catch {
            report(error, context: "mail.checkInbox")
            checkState = .failed(error.localizedDescription)
        }
    }

    // MARK: - Requests

    /// Runs one operation against the current account's provider, refusing while sync is blocked
    /// and feeding failures into the shared circuit breaker.
    func perform<T: Sendable>(_ context: String, _ operation: @Sendable (any MailProvider) async throws -> T) async throws -> T {
        guard settings.enabled else { throw MailError.notSupported }
        guard let account, let provider = backend?.mailProvider(accountID: account.id) else { throw MailError.notSupported }
        guard !isBlocked else { throw MailError.blocked(Self.blockedMessage) }
        do {
            return try await operation(provider)
        } catch {
            report(error, context: context)
            throw error
        }
    }

    /// The first unread page: the popover's lists, and a notification for each new conversation
    /// worth one.
    private func applyUnreadPage(_ conversations: [MailConversationSummary], full: Bool) {
        latestUnread = conversations
        peopleUnread = conversations.filter { !$0.isAutomated }
        unreadPageWasFull = full
        let ids = Set(conversations.map(\.id))
        defer { seenUnreadIDs = (seenUnreadIDs ?? []).union(ids).intersection(ids) }
        guard let seen = seenUnreadIDs, settings.notifyMode != .off else { return }
        let vip = settings.notifyMode == .important ? (backend?.mailVIPNames ?? []) : []
        let fresh = conversations.filter { conversation in
            guard !seen.contains(conversation.id) else { return false }
            if settings.notifyMode == .all { return true }
            guard !conversation.isAutomated else { return false }
            return settings.notifyMode == .people || MailVIP.matches(conversation.primarySender, in: vip) || conversation.importance == .high
        }
        for conversation in fresh.prefix(Self.notificationsPerCheck) {
            notifier(conversation, isExternalSender(conversation) ? (localization?.tr("mail.external") ?? "external") : nil)
        }
    }

    nonisolated static func postNotification(_ conversation: MailConversationSummary, externalLabel: String?) {
        let content = UNMutableNotificationContent()
        // The server's own "external sender" warning is cut from previews, so it is said here.
        content.title = externalLabel.map { conversation.primarySender + " · " + $0 } ?? conversation.primarySender
        content.subtitle = conversation.topic
        content.body = String(conversation.preview.prefix(160))
        content.userInfo = ["conversationID": conversation.id]
        content.threadIdentifier = "owawidget-mail"
        let request = UNNotificationRequest(
            identifier: notificationIdentifierPrefix + String(conversation.id.suffix(24)),
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    private func report(_ error: Error, context: String) {
        if MailCancellation.isCancellation(error) { return }
        log.error("\(context, privacy: .public) failed: \(error.localizedDescription, privacy: .private)")
        // The case alone (`notFound`, `serverError("ErrorAccessDenied")`, a URLError code):
        // other errors' text may quote the server or the mailbox.
        let kind = (error as? MailError).map { "\($0)" } ?? { let e = error as NSError; return "\(e.domain)#\(e.code)" }()
        DiagnosticLog.event("Mail \(context) failed error=\(kind)")
        backend?.reportMailFailure(error, context: context)
    }

    func loadFolders() async throws {
        let loaded = try await perform("mail.folders") { try await $0.mailFolders() }
        folders = MailFolderTree.ordered(loaded)
        if let inbox = folders.first(where: { $0.distinguished == .inbox }) {
            inboxFolderID = inbox.id
            inboxUnreadCount = inbox.unreadCount
        }
        // A remembered folder that is gone falls back to the inbox — judged only on a full tree.
        // The GetFolder fallback (sessiondata failed) returns system folders alone, and taking
        // that for "deleted" would throw the user's choice away over one bad request. The full
        // tree has the root and parents; the fallback's folders have no parent at all.
        let isFullTree = folders.contains { $0.distinguished == .msgfolderroot || $0.parentID != nil }
        if case .id(let id) = panelFolder, isFullTree, !folders.contains(where: { $0.id == id }) {
            resetPanelFolder()
        }
    }

    /// Fresh unread and total counts of every known folder in one `GetFolder` (ids only, no
    /// names or tree): the sidebar follows reading and the mail rules file into subfolders.
    /// Calls closer than `minInterval` apart are skipped.
    func refreshFolderCounts(minInterval: TimeInterval = 10) async {
        guard !folders.isEmpty else { return }
        if let last = lastCountsRefresh, Date().timeIntervalSince(last) < minInterval { return }
        lastCountsRefresh = Date()
        let refs = folders.filter { $0.distinguished != .msgfolderroot }.map { MailFolderRef.id($0.id) }
        var fresh: [String: MailFolder] = [:]
        do {
            for chunk in refs.chunked(100) {
                for folder in try await perform("mail.folderCounts", { try await $0.mailFolderCounts(chunk) }) {
                    fresh[folder.id] = folder
                }
            }
        } catch {
            return  // reported by `perform`; the old counts stay
        }
        folders = folders.map { folder in
            guard let update = fresh[folder.id] else { return folder }
            var copy = folder
            copy.unreadCount = update.unreadCount
            copy.totalCount = update.totalCount
            return copy
        }
        if let inbox = folders.first(where: { $0.distinguished == .inbox }) { inboxUnreadCount = inbox.unreadCount }
    }

    /// The first page of the panel's folder; calls closer than `minInterval` apart are skipped.
    func refreshPanelList(minInterval: TimeInterval = 30) async {
        panelWanted = true
        guard isAvailable, !isBlocked else { return }
        if let loaded = panelListLoaded, Date().timeIntervalSince(loaded) < minInterval { return }
        // One at a time unless asked for a fresh one (a folder switch, the refresh button).
        if panelLoadsInFlight > 0, minInterval > 0 { return }
        let folder = panelFolder
        panelListGeneration += 1
        let generation = panelListGeneration
        panelLoadsInFlight += 1
        defer { panelLoadsInFlight -= 1 }
        do {
            let page = try await perform("mail.panelList") {
                try await $0.mailConversations(in: folder, cursor: .first, filter: .all)
            }
            guard generation == panelListGeneration, folder == panelFolder else { return }
            // Pages scrolled to stay: the rows after the fresh first page's last one are kept
            // (less what moved up into it), and so is the cursor after them. When the first page
            // no longer reaches the old rows (much new mail), there would be a gap: start over.
            let firstIDs = Set(page.conversations.map(\.id))
            let boundary = page.nextCursor == nil ? nil : page.conversations.last.flatMap { last in panelList.firstIndex { $0.id == last.id } }
            let tail = boundary.map { panelList[($0 + 1)...].filter { !firstIDs.contains($0.id) } } ?? []
            if boundary == nil || tail.isEmpty { panelNextCursor = page.nextCursor }
            panelList = page.conversations + tail
            panelListFailed = false
            panelListLoaded = Date()
        } catch {
            // `perform` reported it; the list keeps what it had, and an empty one says why.
            guard generation == panelListGeneration, folder == panelFolder, !MailCancellation.isCancellation(error) else { return }
            panelListFailed = true
        }
    }

    /// The panel's next page, when the list is scrolled to its end.
    func loadMorePanelList() async {
        guard let cursor = panelNextCursor, !isLoadingMorePanelList, panelLoadsInFlight == 0, isAvailable, !isBlocked else { return }
        let folder = panelFolder
        let generation = panelListGeneration
        isLoadingMorePanelList = true
        defer { isLoadingMorePanelList = false }
        do {
            let page = try await perform("mail.panelList") {
                try await $0.mailConversations(in: folder, cursor: cursor, filter: .all)
            }
            // A refresh or a folder switch in the meantime has the list now.
            guard generation == panelListGeneration, folder == panelFolder, cursor == panelNextCursor else { return }
            let known = Set(panelList.map(\.id))
            panelNextCursor = page.nextCursor
            panelList += page.conversations.filter { !known.contains($0.id) }
        } catch {
            // `perform` reported it; the footer stays, so scrolling to it again retries.
        }
    }

    /// Switches the panel to another folder and loads it.
    func selectPanelFolder(_ folder: MailFolderRef) async {
        guard folder != panelFolder else { return }
        panelFolder = folder
        defaults.set(Self.storageValue(folder), forKey: Self.panelFolderKey)
        defaults.set(account?.id.uuidString, forKey: Self.panelFolderAccountKey)
        panelList = []
        panelNextCursor = nil
        panelListLoaded = nil
        panelListFailed = false
        await refreshPanelList(minInterval: 0)
    }

    private func resetPanelFolder() {
        panelFolder = .distinguished(.inbox)
        defaults.removeObject(forKey: Self.panelFolderKey)
        defaults.removeObject(forKey: Self.panelFolderAccountKey)
        panelList = []
        panelNextCursor = nil
        panelListLoaded = nil
        panelListFailed = false
    }

    /// The folder tree for the panel, when the mail window has not loaded it yet.
    func loadFoldersIfNeeded() async {
        guard folders.isEmpty, isAvailable, !isBlocked else { return }
        try? await loadFolders()
    }

    /// Marks everything in the panel's folder read and shows it at once: the rows lose their
    /// unread mark and the folder its count before the fresh counts come back. The counts are
    /// asked for even when marking stopped halfway, so the panel shows what the server has.
    func markPanelFolderRead() async throws {
        let folder = panelFolder
        let folderID = panelFolderInfo?.id
        do {
            try await markAllRead(in: folder)
        } catch {
            await refreshFolderCounts(minInterval: 0)
            await checkInbox()
            throw error
        }
        if folder == panelFolder { panelList = panelList.map { $0.with(unreadCount: 0) } }
        if let folderID {
            folders = folders.map { entry in
                guard entry.id == folderID else { return entry }
                var copy = entry
                copy.unreadCount = 0
                return copy
            }
        }
        await refreshFolderCounts(minInterval: 0)
        await checkInbox()
    }

    /// The panel folder's entry in the tree (for its name and unread count).
    var panelFolderInfo: MailFolder? {
        switch panelFolder {
        case .distinguished(let name): folders.first { $0.distinguished == name }
        case .id(let id): folders.first { $0.id == id }
        }
    }

    static func storageValue(_ folder: MailFolderRef) -> String {
        switch folder {
        case .distinguished(let name): "distinguished:" + name.rawValue
        case .id(let id): "id:" + id
        }
    }

    static func folderRef(storageValue value: String?) -> MailFolderRef? {
        guard let value else { return nil }
        if value.hasPrefix("distinguished:"), let name = MailDistinguishedFolder(rawValue: String(value.dropFirst(14))) {
            return .distinguished(name)
        }
        if value.hasPrefix("id:"), value.count > 3 { return .id(String(value.dropFirst(3))) }
        return nil
    }

    /// Moves folder unread counts right away, before the server confirms them.
    func adjustFolderUnread(_ deltas: [String: Int]) {
        guard !deltas.isEmpty else { return }
        folders = folders.map { folder in
            guard let delta = deltas[folder.id], delta != 0 else { return folder }
            var copy = folder
            copy.unreadCount = max(0, folder.unreadCount + delta)
            return copy
        }
    }

    func conversations(in folder: MailFolderRef, cursor: MailListCursor, filter: MailListFilter) async throws -> MailConversationPage {
        try await perform("mail.list") { try await $0.mailConversations(in: folder, cursor: cursor, filter: filter) }
    }

    /// A thread, from the cache when `useCache` and it is there.
    ///
    /// Deleted Items is left out of a thread, except when the conversation is opened from there
    /// (`includingDeleted`): then it would come back empty. Such a thread bypasses the cache, so
    /// the two shapes of one conversation never stand in for each other.
    func thread(_ conversationID: String, useCache: Bool = true, includingDeleted: Bool = false) async throws -> MailThread {
        if !includingDeleted, useCache, let cached = threadCache[conversationID] {
            touch(conversationID)
            return cached
        }
        let ignored = includingDeleted ? [] : folders.filter { $0.distinguished == .deleteditems }.map(\.id)
        let loaded = try await perform("mail.thread") {
            try await $0.mailThread(conversationID: conversationID, ignoringFolders: ignored)
        }
        if !includingDeleted { store(loaded) }
        return loaded
    }

    func fullMessage(_ ref: MailItemRef) async throws -> MailMessage {
        try await perform("mail.message") { try await $0.mailMessage(ref) }
    }

    func attachment(_ info: MailAttachmentInfo) async throws -> Data {
        guard info.size <= OWAClient.mailAttachmentLimit else { throw MailError.tooLarge(info.size) }
        let id = info.id
        return try await perform("mail.attachment") { try await $0.mailAttachment(id: id, maxBytes: OWAClient.mailAttachmentLimit) }
    }

    /// Inline images of a message by `ContentId`, for `cid:` references in its body. Images that
    /// fail or are too large are left out: the body shows the server's blank pixel instead.
    func inlineImages(for message: MailMessage) async -> [String: (data: Data, type: String)] {
        var images: [String: (data: Data, type: String)] = [:]
        var total = 0
        for info in message.attachments where info.isInline && info.contentType.hasPrefix("image/") {
            guard let contentID = info.contentID, info.size <= Self.inlineImageLimit, total + info.size <= 4 * Self.inlineImageLimit else { continue }
            let id = info.id
            if let data = try? await perform("mail.inlineImage", { try await $0.mailAttachment(id: id, maxBytes: Self.inlineImageLimit) }) {
                images[contentID] = (data, info.contentType)
                total += data.count
            }
        }
        return images
    }

    @discardableResult
    func setRead(_ message: MailMessage, _ isRead: Bool) async throws -> MailMessage {
        let ref = message.ref
        let target = MailItemTarget(ref, kind: message.kind)
        let newRef = try await perform("mail.setRead") { try await $0.mailUpdate([target], .isRead(isRead)) }.first ?? ref
        let updated = message.with(ref: newRef, isRead: isRead)
        replaceInCache(updated)
        if message.parentFolderID == nil || message.parentFolderID == inboxFolderID {
            if let count = inboxUnreadCount { inboxUnreadCount = max(0, count + (isRead ? -1 : 1)) }
            if isRead, let conversationID = message.conversationID { dropFromUnreadLists([conversationID]) }
        }
        changeGeneration += 1
        return updated
    }

    @discardableResult
    func setCategories(_ message: MailMessage, _ categories: [String]) async throws -> MailMessage {
        let ref = message.ref
        let target = MailItemTarget(ref, kind: message.kind)
        let newRef = try await perform("mail.categories") { try await $0.mailUpdate([target], .categories(categories)) }.first ?? ref
        let updated = message.with(ref: newRef, categories: categories)
        replaceInCache(updated)
        changeGeneration += 1
        return updated
    }

    @discardableResult
    func setFlag(_ message: MailMessage, _ flagged: Bool) async throws -> MailMessage {
        let ref = message.ref
        let target = MailItemTarget(ref, kind: message.kind)
        let newRef = try await perform("mail.flag") { try await $0.mailUpdate([target], .flag(flagged ? .flagged : .notFlagged)) }.first ?? ref
        let updated = message.with(ref: newRef, isFlagged: flagged)
        replaceInCache(updated)
        changeGeneration += 1
        return updated
    }

    /// Moves messages; "delete" is a move to Deleted Items. Ids change, so the cached thread goes.
    func move(_ messages: [MailMessage], to folder: MailFolderRef) async throws {
        let refs = messages.map(\.ref)
        _ = try await perform("mail.move") { try await $0.mailMove(refs, to: folder) }
        let conversations = Set(messages.compactMap(\.conversationID))
        for conversationID in conversations { evict(conversationID) }
        dropFromUnreadLists(conversations)
        changeGeneration += 1
    }

    // MARK: - Whole conversations (list actions)

    /// Marks conversations read or unread in one request. "Unread" marks only the newest message,
    /// as Outlook does; "read" marks every message the folder holds.
    func setRead(conversations: [MailConversationSummary], _ isRead: Bool) async throws {
        // `IsRead` goes as `Message` whatever the item is (`OWAMailPayloads.itemType`): which
        // message is an invitation does not matter here, so no thread is read to find out.
        let refs = conversations.flatMap { conversation in
            (isRead ? conversation.itemRefs : Array(conversation.itemRefs.prefix(1))).map { MailItemTarget($0, kind: .note) }
        }
        guard !refs.isEmpty else { return }
        for chunk in refs.chunked(Self.bulkPageSize) {
            _ = try await perform("mail.setRead") { try await $0.mailUpdate(chunk, .isRead(isRead)) }
        }
        for conversation in conversations { evict(conversation.id) }
        if isRead { dropFromUnreadLists(Set(conversations.map(\.id))) }
        let inboxDelta = conversations.filter { $0.parentFolderID == nil || $0.parentFolderID == inboxFolderID }
            .reduce(0) { $0 + (isRead ? -$1.unreadCount : (($1.unreadCount == 0) ? 1 : 0)) }
        if let count = inboxUnreadCount { inboxUnreadCount = max(0, count + inboxDelta) }
        changeGeneration += 1
    }

    func setFlag(conversations: [MailConversationSummary], _ flagged: Bool) async throws {
        var newest: [MailItemTarget] = []
        for conversation in conversations {
            if let first = await targets(in: conversation).first { newest.append(first) }
        }
        let refs = newest
        guard !refs.isEmpty else { return }
        _ = try await perform("mail.flag") { try await $0.mailUpdate(refs, .flag(flagged ? .flagged : .notFlagged)) }
        for conversation in conversations { evict(conversation.id) }
        changeGeneration += 1
    }

    /// The conversation's messages with what each one is. `FindConversation` names only the
    /// classes the thread holds, not which message has which: when an invitation and replies to
    /// it share a thread, the thread itself says (a message it does not hold counts as a note).
    /// A conversation listed in Deleted Items is read with that folder, or its messages are not
    /// in the thread at all.
    private func targets(in conversation: MailConversationSummary) async -> [MailItemTarget] {
        if let kind = conversation.uniformItemKind {
            return conversation.itemRefs.map { MailItemTarget($0, kind: kind) }
        }
        let deletedItemsID = folders.first { $0.distinguished == .deleteditems }?.id
        let inDeletedItems = conversation.parentFolderID != nil && conversation.parentFolderID == deletedItemsID
        let kinds = Dictionary(
            ((try? await thread(conversation.id, includingDeleted: inDeletedItems))?.messages ?? []).map { ($0.ref.id, $0.kind) },
            uniquingKeysWith: { first, _ in first }
        )
        return conversation.itemRefs.map { MailItemTarget($0, kind: kinds[$0.id] ?? .note) }
    }

    func move(conversations: [MailConversationSummary], to folder: MailFolderRef) async throws {
        let refs = conversations.flatMap(\.itemRefs)
        guard !refs.isEmpty else { return }
        for chunk in refs.chunked(Self.bulkPageSize) {
            _ = try await perform("mail.move") { try await $0.mailMove(chunk, to: folder) }
        }
        let ids = Set(conversations.map(\.id))
        for id in ids { evict(id) }
        dropFromUnreadLists(ids)
        changeGeneration += 1
    }

    /// Marks everything unread in a folder as read: pages of unread messages (`FindItem`), each
    /// marked with one `UpdateItem`. Stops at `markAllReadLimit`; returns how many were marked.
    @discardableResult
    func markAllRead(in folder: MailFolderRef, progress: ((Int) -> Void)? = nil) async throws -> Int {
        var marked = 0
        while marked < Self.markAllReadLimit {
            // Always the first page: what was just marked drops out of the unread view.
            let page = try await perform("mail.markAllRead") {
                try await $0.mailItems(in: folder, cursor: .first, filter: .unread, count: Self.bulkPageSize)
            }
            let refs = page.items.filter { !$0.isRead }.map { MailItemTarget($0.ref, kind: $0.kind) }
            guard !refs.isEmpty else { break }
            _ = try await perform("mail.markAllRead") { try await $0.mailUpdate(refs, .isRead(true)) }
            marked += refs.count
            progress?(marked)
            if page.nextCursor == nil { break }
        }
        threadCache = [:]
        threadOrder = []
        if case .distinguished(.inbox) = folder { applyUnreadPage([], full: false); inboxUnreadCount = 0 }
        if case .id(let id) = folder, id == inboxFolderID { applyUnreadPage([], full: false); inboxUnreadCount = 0 }
        changeGeneration += 1
        return marked
    }

    private func dropFromUnreadLists(_ conversationIDs: Set<String>) {
        latestUnread.removeAll { conversationIDs.contains($0.id) }
        peopleUnread.removeAll { conversationIDs.contains($0.id) }
    }

    // MARK: - Meetings

    /// Answers a meeting request from its message, through the calendar (so the popover updates).
    func respond(to message: MailMessage, action: MeetingResponseAction) async throws -> Bool {
        guard let calendarItemID = message.meeting?.associatedCalendarItemID, let backend else { return false }
        guard !isBlocked else { throw MailError.blocked(Self.blockedMessage) }
        let answered = try await backend.respondToMailMeeting(calendarItemID: calendarItemID, action: action)
        if answered { changeGeneration += 1 }
        return answered
    }

    func meetingResponse(for message: MailMessage) -> MeetingResponseType? {
        message.meeting?.associatedCalendarItemID.flatMap { backend?.mailMeetingResponse(calendarItemID: $0) }
    }

    /// Mail about a meeting: conversations with its subject, and mail from its people. Two
    /// searches; called only when the user asks for it in the meeting card.
    func relatedMail(title: String, people: [String], limit: Int = 8) async throws -> [MailConversationSummary] {
        var results: [MailConversationSummary] = []
        let subject = MailRelatedSearch.subjectQuery(title)
        if !subject.isEmpty {
            results += try await search(MailSearchQuery(text: subject), offset: 0, count: limit).conversations
        }
        let addresses = Array(people.prefix(3))
        for address in addresses where results.count < limit * 2 {
            var query = MailSearchQuery(text: "")
            query.from = [address]
            query.receivedFrom = AppTimeZone.calendar.date(byAdding: .day, value: -30, to: Date())
            results += try await search(query, offset: 0, count: 5).conversations
        }
        endSearch()
        var seen = Set<String>()
        return results
            .filter { seen.insert($0.id).inserted }
            .sorted { ($0.lastDelivery ?? .distantPast) > ($1.lastDelivery ?? .distantPast) }
            .prefix(limit)
            .map { $0 }
    }

    func search(_ query: MailSearchQuery, offset: Int, count: Int = OWAMailPayloads.pageSize) async throws -> MailSearchPage {
        try await perform("mail.search") { try await $0.mailSearch(query, offset: offset, count: count) }
    }

    func endSearch() {
        guard let account, let provider = backend?.mailProvider(accountID: account.id), !isBlocked else { return }
        Task { await provider.mailEndSearch() }
    }

    /// Sends (or saves) a message the user wrote in the compose window.
    @discardableResult
    /// Saves to Drafts. Sending never goes through here: see `prepareSend`.
    func saveDraft(_ outgoing: MailOutgoing) async throws -> MailItemRef? {
        var copy = outgoing
        copy.send = false
        let draft = copy
        let result = try await perform("mail.draft") { try await $0.mailSend(draft) }
        changeGeneration += 1
        return result
    }

    /// Step one of sending: a draft on the server, read back. Nothing is sent yet; the draft is
    /// deleted again if it cannot be read.
    func prepareSend(_ outgoing: MailOutgoing) async throws -> MailPreparedSend {
        var copy = outgoing
        copy.send = false
        let draft = copy
        guard let ref = try await perform("mail.prepare", { try await $0.mailSend(draft) }) else {
            throw MailError.serverError("no draft id")
        }
        do {
            let message = try await perform("mail.prepare.review") { try await $0.mailDraftForReview(ref) }
            return try MailPreparedSend.make(draft: message, outgoing: outgoing)
        } catch {
            try? await perform("mail.prepare.discard") { try await $0.mailDeleteDraft(ref) }
            throw error
        }
    }

    /// Step two: sends the reviewed draft as it is.
    func sendPrepared(_ prepared: MailPreparedSend) async throws {
        try await perform("mail.send") { try await $0.mailSendDraft(prepared.draft) }
        if let ref = prepared.outgoing.reference,
           let conversation = threadCache.first(where: { $0.value.messages.contains { $0.ref.id == ref.id } })?.key {
            evict(conversation)
        }
        changeGeneration += 1
    }

    /// Drops a reviewed draft the user decided not to send.
    func discardPrepared(_ prepared: MailPreparedSend) async {
        try? await perform("mail.discard") { try await $0.mailDeleteDraft(prepared.draft) }
    }

    /// Looks the user's own address up once per account.
    /// Without it nothing can be told external, so it is looked up again until it is known: by
    /// the mail window, the compose window and every inbox check.
    func resolveOwnAddress() async {
        guard ownAddress == nil, !isResolvingOwnAddress, isAvailable, !isBlocked, let account, let backend else { return }
        isResolvingOwnAddress = true
        defer { isResolvingOwnAddress = false }
        let address = await backend.ownMailAddress(accountID: account.id)
        if self.account?.id == account.id { ownAddress = address }
    }

    var ownDomain: String? {
        ownAddress.flatMap { $0.split(separator: "@").last.map { String($0).lowercased() } }
    }

    /// The calendar's time for the meeting an invitation in the list is about.
    func meetingInterval(forTopic topic: String) -> DateInterval? {
        backend?.mailMeetingInterval(topic: topic)
    }

    /// The sender is outside the organization: the server's warning was in the preview, or the
    /// address is in another domain. Every place that shows a stripped preview tags it with this.
    func isExternalSender(_ conversation: MailConversationSummary) -> Bool {
        conversation.hasExternalBanner || isExternal(conversation.senderEmail)
    }

    /// Outside the user's mail domain; `false` while the domain is unknown.
    func isExternal(_ email: String?) -> Bool {
        guard let email, let domain = ownDomain, let at = email.lastIndex(of: "@") else { return false }
        let other = email[email.index(after: at)...].lowercased()
        return other != domain && !other.hasSuffix("." + domain)
    }

    /// Address book suggestions for the compose window's recipient fields.
    func suggestRecipients(_ query: String) async -> [ResolvedAttendee] {
        guard isAvailable, !isBlocked, let account, let backend, query.trimmingCharacters(in: .whitespaces).count >= 2 else { return [] }
        do {
            return try await backend.findMailPeople(query: query, accountID: account.id)
        } catch {
            report(error, context: "mail.findPeople")
            return []
        }
    }

    // MARK: - Window and compose

    func open(conversationID: String, folder: MailFolderRef? = nil) {
        openRequest = MailOpenRequest(conversationID: conversationID, folder: folder)
    }

    func compose(_ request: MailComposeRequest) {
        composeRequest = request
    }

    func windowDidAppear() {
        isWindowOpen = true
        cacheClearTask?.cancel()
        cacheClearTask = nil
    }

    func windowDidDisappear() {
        isWindowOpen = false
        endSearch()
        cacheClearTask?.cancel()
        cacheClearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.cacheLingerAfterClose))
            guard !Task.isCancelled, let self, !self.isWindowOpen else { return }
            self.threadCache = [:]
            self.threadOrder = []
        }
    }

    // MARK: - Cache

    private func store(_ thread: MailThread) {
        threadCache[thread.id] = thread
        touch(thread.id)
        while threadOrder.count > Self.threadCacheLimit {
            let oldest = threadOrder.removeFirst()
            threadCache[oldest] = nil
        }
    }

    private func touch(_ id: String) {
        threadOrder.removeAll { $0 == id }
        threadOrder.append(id)
    }

    private func evict(_ id: String) {
        threadCache[id] = nil
        threadOrder.removeAll { $0 == id }
    }

    private func replaceInCache(_ message: MailMessage) {
        guard let conversationID = message.conversationID ?? threadCache.first(where: { $0.value.messages.contains { $0.ref.id == message.ref.id } })?.key,
              let thread = threadCache[conversationID] else { return }
        let messages = thread.messages.map { $0.ref.id == message.ref.id ? message : $0 }
        threadCache[conversationID] = MailThread(id: thread.id, messages: messages, totalMessageCount: thread.totalMessageCount)
    }

    var cachedThreadCount: Int { threadCache.count }

    private func providersChanged() {
        clearState()
        // A folder id belongs to one account: another account starts from its inbox. Providers
        // are rebuilt at launch and on every credentials edit too, so only a different account
        // counts. (Turning mail off and on keeps the choice: `clearState` does not touch it.)
        if case .id = panelFolder, let owner = defaults.string(forKey: Self.panelFolderAccountKey),
           owner != account?.id.uuidString {
            resetPanelFolder()
        }
        if settings.enabled { Task { await checkInbox() } }
    }

    private func clearState() {
        threadCache = [:]
        threadOrder = []
        folders = []
        inboxUnreadCount = nil
        latestUnread = []
        panelList = []
        panelNextCursor = nil
        panelListLoaded = nil
        panelListFailed = false
        panelWanted = false
        lastChecked = nil
        inboxFolderID = nil
        ownAddress = nil
        checkState = .idle
    }
}

/// Folder order for the sidebar: system folders first in a fixed order, then the rest as a tree
/// sorted by name, children right after their parent.
enum MailFolderTree {
    static let systemOrder: [MailDistinguishedFolder] = [.inbox, .drafts, .sentitems, .archive, .deleteditems, .junkemail, .outbox]

    static func ordered(_ folders: [MailFolder]) -> [MailFolder] {
        let system = systemOrder.compactMap { name in folders.first { $0.distinguished == name } }
        let systemIDs = Set(system.map(\.id))
        let root = folders.first { $0.distinguished == .msgfolderroot }
        let rest = folders.filter { !systemIDs.contains($0.id) && $0.id != root?.id }
        let ids = Set(folders.map(\.id))
        var byParent: [String: [MailFolder]] = [:]
        var tops: [MailFolder] = []
        for folder in rest {
            if let parent = folder.parentID, ids.contains(parent), parent != root?.id {
                byParent[parent, default: []].append(folder)
            } else {
                tops.append(folder)
            }
        }
        var result = system
        var visited = Set<String>()
        func appendTree(_ folder: MailFolder) {
            guard visited.insert(folder.id).inserted else { return }
            if !systemIDs.contains(folder.id) { result.append(folder) }
            for child in (byParent[folder.id] ?? []).sorted(by: nameOrder) { appendTree(child) }
        }
        // Children of system folders (Inbox subfolders) follow the custom ones, under their parent.
        for folder in system { for child in (byParent[folder.id] ?? []).sorted(by: nameOrder) { appendTree(child) } }
        for folder in tops.sorted(by: nameOrder) { appendTree(folder) }
        return result
    }

    /// Nesting depth below the mailbox root, for indentation.
    static func depth(of folder: MailFolder, in folders: [MailFolder]) -> Int {
        let byID = Dictionary(folders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var depth = 0
        var current = folder.parentID
        while let id = current, let parent = byID[id], depth < 8 {
            depth += 1
            current = parent.parentID
        }
        return depth
    }

    private static func nameOrder(_ a: MailFolder, _ b: MailFolder) -> Bool {
        a.displayName.localizedStandardCompare(b.displayName) == .orderedAscending
    }
}

/// The words of a meeting title worth searching mail for: no "RE:"/"FW:", no brackets noise.
enum MailRelatedSearch {
    static func subjectQuery(_ title: String) -> String {
        var text = title
        for prefix in ["re:", "fw:", "fwd:", "отв:", "пересл:"] {
            while text.lowercased().hasPrefix(prefix) { text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces) }
        }
        let words = text
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 }
        return words.prefix(6).joined(separator: " ")
    }
}

extension Array {
    func chunked(_ size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
