import AppKit
import Foundation
import Quartz
import SwiftUI
import UniformTypeIdentifiers

/// Search filters as the window edits them; turned into a `MailSearchQuery` on submit.
struct MailSearchFilters: Equatable {
    enum Period: String, CaseIterable, Identifiable {
        case any, week, month, year
        var id: String { rawValue }
        var localizationKey: String { "mail.search.period.\(rawValue)" }
    }

    var text = ""
    var mailboxWide = true
    var from: [MailSearchRefiner] = []
    var period: Period = .any
    var hasAttachments = false
    var folderRefiner: MailSearchRefiner?

    func query(currentFolder: MailFolderRef, now: Date = Date(), calendar: Calendar = AppTimeZone.calendar) -> MailSearchQuery {
        var query = MailSearchQuery(text: text)
        if mailboxWide {
            query.scope = .mailbox
        } else {
            switch currentFolder {
            case .distinguished(let name): query.scope = .distinguished(name)
            case .id(let id): query.scope = .folder(id: id)
            }
        }
        query.from = from.compactMap { refiner in
            if case .sender(_, let email, _) = refiner { return email }
            return nil
        }
        query.hasAttachments = hasAttachments ? true : nil
        if case .folder(let refinerID, _, _)? = folderRefiner { query.folderRefinerID = refinerID }
        let today = calendar.startOfDay(for: now)
        switch period {
        case .any: break
        case .week: query.receivedFrom = calendar.date(byAdding: .day, value: -7, to: today)
        case .month: query.receivedFrom = calendar.date(byAdding: .month, value: -1, to: today)
        case .year: query.receivedFrom = calendar.date(byAdding: .year, value: -1, to: today)
        }
        if query.receivedFrom != nil { query.receivedTo = now }
        return query
    }
}

/// The "Open in OWA" link for a message.
enum MailOWALink {
    static func url(serverURL: String, itemID: String) -> URL? {
        guard let base = try? OWAClient.parseBaseURL(serverURL),
              var components = URLComponents(url: base.appendingPathComponent("owa/"), resolvingAgainstBaseURL: false) else { return nil }
        components.queryItems = [
            URLQueryItem(name: "ItemID", value: itemID),
            URLQueryItem(name: "exvsurl", value: "1"),
            URLQueryItem(name: "viewmodel", value: "ReadMessageItem"),
        ]
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
            .replacingOccurrences(of: "/", with: "%2F")
        return components.url
    }
}

/// Saved attachments carry the quarantine attribute, as a browser download would: Gatekeeper
/// checks anything executable before it runs.
enum MailAttachmentFiles {
    static func markQuarantined(_ url: URL) {
        var values = URLResourceValues()
        values.quarantineProperties = [
            kLSQuarantineAgentNameKey as String: "OWA Widget",
            kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload as String,
        ]
        var target = url
        try? target.setResourceValues(values)
    }

    /// A private folder for Quick Look copies, emptied when the mail window closes.
    static var previewDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("owawidget-mail-preview", isDirectory: true)
    }

    static func preparePreviewDirectory() throws -> URL {
        let directory = previewDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        return directory
    }

    static func clearPreviews() {
        try? FileManager.default.removeItem(at: previewDirectory)
    }

    /// A file name safe to write: no path separators, no leading dots.
    static func safeFileName(_ name: String) -> String {
        var cleaned = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        return cleaned.isEmpty ? "attachment" : String(cleaned.prefix(200))
    }
}

@MainActor
final class MailQuickLook: NSObject, QLPreviewPanelDataSource {
    static let shared = MailQuickLook()
    private var url: URL?

    func show(_ url: URL) {
        self.url = url
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { 1 }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated { url as NSURL? }
    }
}

/// A row of the conversation list: one conversation, or every conversation of one system sender
/// folded together.
enum MailListRow: Identifiable, Equatable {
    case conversation(MailConversationSummary)
    case bundle(sender: String, conversations: [MailConversationSummary])

    var id: String {
        switch self {
        case .conversation(let conversation): conversation.id
        case .bundle(let sender, _): "bundle:" + sender
        }
    }

    /// The date the row sorts by: a bundle sits at its newest conversation.
    var date: Date? {
        switch self {
        case .conversation(let conversation): conversation.lastDelivery
        case .bundle(_, let conversations): conversations.first?.lastDelivery
        }
    }

    /// Builds the rows: conversations in their order, those of a system sender that appears more
    /// than once folded into a bundle at the place of its newest conversation.
    static func rows(_ conversations: [MailConversationSummary], bundleAutomated: Bool) -> [MailListRow] {
        guard bundleAutomated else { return conversations.map { .conversation($0) } }
        var bySender: [String: [MailConversationSummary]] = [:]
        for conversation in conversations where conversation.isAutomated {
            bySender[conversation.primarySender, default: []].append(conversation)
        }
        var rows: [MailListRow] = []
        var placed = Set<String>()
        for conversation in conversations {
            if conversation.isAutomated, let group = bySender[conversation.primarySender], group.count > 1 {
                if placed.insert(conversation.primarySender).inserted {
                    rows.append(.bundle(sender: conversation.primarySender, conversations: group))
                }
            } else {
                rows.append(.conversation(conversation))
            }
        }
        return rows
    }
}

/// Failures that mean the server was not reached (VPN down, no network, DNS), as opposed to the
/// server answering with an error.
enum MailConnectivity {
    private static let codes: Set<Int> = [
        NSURLErrorNotConnectedToInternet, NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost,
        NSURLErrorDNSLookupFailed, NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost,
        NSURLErrorInternationalRoamingOff, NSURLErrorDataNotAllowed, NSURLErrorSecureConnectionFailed,
    ]

    static func isConnectionError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain, codes.contains(ns.code) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error { return isConnectionError(underlying) }
        return false
    }
}

/// A request the window waits for with a spinner on the button that started it; that button
/// takes no second click meanwhile.
enum MailPendingAction: Hashable {
    case refresh
    case attachment(String)
    case meetingResponse(String)
    case fullBody(String)
    case remoteImages(String)
}

/// A message body ready for the reader, built off the main thread.
struct MailReaderDocument: Sendable {
    /// What the build was made from: a newer body (the quoted history) or newly arrived images
    /// need a new build.
    struct Key: Hashable, Sendable {
        let bodyLength: Int
        let isFull: Bool
        let inlineImages: Int
        let remoteImages: Int
    }

    let key: Key
    let html: String
    let hasRemoteImages: Bool
    let isVisuallyEmpty: Bool
}

/// The list shows what was loaded earlier because the latest load failed.
struct MailStaleListNotice: Equatable {
    let loadedAt: Date
    let isConnectionError: Bool
}

@MainActor
final class MailWindowModel: ObservableObject {
    @Published private(set) var folders: [MailFolder] = []
    @Published var selectedFolder: MailFolderRef = .distinguished(.inbox)
    @Published var mode: MailListMode = .all {
        didSet {
            guard mode != oldValue else { return }
            if mode.serverFilter != oldValue.serverFilter {
                listShowsFolderPage = false
                staleList = nil
                Task { await reloadList() }
            }
        }
    }
    @Published private(set) var conversations: [MailConversationSummary] = [] {
        // Reads, flags and moves made since the snapshot stay in it, so a later failure does not
        // bring back an older picture of the folder.
        didSet {
            guard listShowsFolderPage, let key = currentListKey, let snapshot = listSnapshots[key] else { return }
            listSnapshots[key] = ListSnapshot(conversations: conversations, nextCursor: nextCursor, totalInView: totalInView, loadedAt: snapshot.loadedAt)
        }
    }
    /// Set while the list shows an earlier load because the latest one failed.
    @Published private(set) var staleList: MailStaleListNotice?

    /// The last good first page of each folder and filter, in memory only (never on disk), so a
    /// dropped VPN does not empty a list that was on screen a minute ago.
    private struct ListKey: Hashable {
        let folder: MailFolderRef
        let filter: MailListFilter
    }
    private struct ListSnapshot {
        let conversations: [MailConversationSummary]
        let nextCursor: MailListCursor?
        let totalInView: Int?
        let loadedAt: Date
    }
    private var listSnapshots: [ListKey: ListSnapshot] = [:]
    /// The list holds a page of the selected folder (loaded or restored), not search results or
    /// leftovers of a search being cleared: only then do its changes go into the snapshot.
    private var listShowsFolderPage = false
    private static let snapshotLimit = 20
    private var currentListKey: ListKey? { ListKey(folder: selectedFolder, filter: mode.serverFilter) }
    @Published private(set) var nextCursor: MailListCursor?
    @Published private(set) var isLoadingList = false
    @Published private(set) var listError: String?
    @Published private(set) var totalInView: Int?
    /// Bundles opened in the list, by sender.
    @Published var expandedBundles: Set<String> = []
    /// Folders opened in the sidebar tree, by id. All start closed (an inbox with a few dozen
    /// rule folders would push Sent and the user's own folders off the screen) and the choice is
    /// remembered between launches.
    @Published var expandedFolderIDs: Set<String> = [] {
        didSet { defaults.set(Array(expandedFolderIDs).sorted(), forKey: Self.expandedFoldersKey) }
    }
    static let expandedFoldersKey = "mailExpandedFolderIDs"
    private var countsTask: Task<Void, Never>?
    private let defaults: UserDefaults

    /// The conversation shown in the reader.
    @Published private(set) var selectedConversationID: String?
    /// Conversations picked with ⌘/⇧-click for a list action.
    @Published private(set) var selectedIDs: Set<String> = []
    @Published private(set) var thread: MailThread?
    @Published private(set) var isLoadingThread = false
    @Published private(set) var threadError: String?
    /// Messages of the open thread shown expanded; the newest and every unread one by default.
    @Published var expandedMessageIDs: Set<String> = []
    @Published private(set) var inlineImages: [String: [String: (data: Data, type: String)]] = [:]
    @Published private(set) var remoteImages: [String: [String: (data: Data, type: String)]] = [:]
    /// Full text (with the quoted history) loaded on request, by message id.
    @Published private(set) var fullBodies: [String: String] = [:]
    /// Reader documents of the open thread, by message id. Building one scans the whole body
    /// (tens of milliseconds for a long notification, more in a debug build); done in the view's
    /// body it ran on the main thread on every change of the model, and the window stood still
    /// for a moment after each click.
    @Published private(set) var readerDocuments: [String: MailReaderDocument] = [:]
    /// Builds on their way, by message id: what each is made from.
    private var readerDocumentBuilds: [String: MailReaderDocument.Key] = [:]

    @Published var searchFilters = MailSearchFilters()
    @Published private(set) var activeSearch: MailSearchQuery?
    @Published private(set) var searchTerms: [String] = []
    @Published private(set) var refiners: [MailSearchRefiner] = []
    @Published private(set) var searchMoreAvailable = false

    @Published var pendingLink: MailLinkActivation?
    @Published var actionError: String?
    /// "Mark everything in this folder as read?" is on screen.
    @Published var confirmsMarkAllRead = false
    /// Progress text of a long list action ("Marked 150…").
    @Published private(set) var bulkProgress: Int?
    @Published private(set) var meetingAnswers: [String: MeetingResponseType] = [:]
    @Published private(set) var pending: Set<MailPendingAction> = []
    /// The latest read, flag or category change of each message, by id: it is already on screen,
    /// and the next one waits for it (it needs the change key the server answers with).
    private var messageChanges: [String: Task<Void, Never>] = [:]
    /// Messages whose changes are still going, by id, as the server last confirmed them: the
    /// changes it has accepted so far and its latest change key.
    private var messageConfirmed: [String: MailMessage] = [:]

    let service: MailService
    private var markReadTask: Task<Void, Never>?
    private var listGeneration = 0

    init(service: MailService, defaults: UserDefaults = .standard) {
        self.service = service
        self.defaults = defaults
        expandedFolderIDs = Set(defaults.stringArray(forKey: Self.expandedFoldersKey) ?? [])
    }

    var isSearching: Bool { activeSearch != nil }

    var selectedFolderInfo: MailFolder? {
        switch selectedFolder {
        case .distinguished(let name): folders.first { $0.distinguished == name }
        case .id(let id): folders.first { $0.id == id }
        }
    }

    func isSelected(_ folder: MailFolder) -> Bool {
        switch selectedFolder {
        case .distinguished(let name): folder.distinguished == name
        case .id(let id): folder.id == id
        }
    }

    /// Every category seen in what is loaded, for the category menu.
    var knownCategories: [String] {
        var names = Set(conversations.flatMap(\.categories))
        names.formUnion(thread?.messages.flatMap(\.categories) ?? [])
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Shows a failure in the banner. A cancelled request is the user moving on, not a failure.
    func show(_ error: Error) {
        guard !MailCancellation.isCancellation(error) else { return }
        actionError = error.localizedDescription
    }

    // MARK: - List

    var rows: [MailListRow] {
        MailListRow.rows(conversations, bundleAutomated: service.settings.bundleAutomated && !isSearching)
    }

    /// Conversations in the order the user sees them, bundles expanded or not.
    private var orderedVisibleIDs: [String] {
        rows.flatMap { row -> [String] in
            switch row {
            case .conversation(let conversation): [conversation.id]
            case .bundle(let sender, let list): expandedBundles.contains(sender) ? list.map(\.id) : [list[0].id]
            }
        }
    }

    // MARK: - Loading

    /// Loads the folders and the list; `folder`, when given, is shown instead of the current one
    /// (the window opened from the inbox panel), so the current one is not loaded for nothing.
    func start(folder: MailFolderRef? = nil) async {
        // Snapshots belong to one account.
        listSnapshots = [:]
        listShowsFolderPage = false
        staleList = nil
        if let folder { selectedFolder = folder }
        await loadFolders()
        await reloadList()
    }

    func loadFolders() async {
        do {
            try await service.loadFolders()
            folders = service.folders
        } catch {
            if folders.isEmpty, !MailCancellation.isCancellation(error) { listError = error.localizedDescription }
        }
    }

    func select(folder: MailFolder) {
        select(ref: folder.distinguished.map { .distinguished($0) } ?? .id(folder.id))
    }

    func select(ref: MailFolderRef) {
        guard ref != selectedFolder || isSearching else { return }
        clearSearch()
        // The old folder's rows stay until the new one loads: not this folder's page meanwhile,
        // and the old folder's "loaded at" notice does not belong to the new one.
        listShowsFolderPage = false
        staleList = nil
        selectedFolder = ref
        clearSelection()
        Task { await reloadList() }
    }

    func toggleFolder(_ folder: MailFolder) {
        if expandedFolderIDs.contains(folder.id) { expandedFolderIDs.remove(folder.id) } else { expandedFolderIDs.insert(folder.id) }
    }

    /// Nothing open, nothing picked: after a folder or a search changes, the reader must not keep
    /// showing a conversation from somewhere else.
    func clearSelection() {
        markReadTask?.cancel()
        selectedConversationID = nil
        selectedIDs = []
        thread = nil
        threadError = nil
        expandedMessageIDs = []
        readerDocuments = [:]
        readerDocumentBuilds = [:]
    }

    func reloadList() async {
        listGeneration += 1
        let generation = listGeneration
        isLoadingList = true
        listError = nil
        defer { if generation == listGeneration { isLoadingList = false } }
        do {
            if let activeSearch {
                let page = try await service.search(activeSearch, offset: 0)
                guard generation == listGeneration else { return }
                apply(searchPage: page, appending: false)
            } else {
                let page = try await service.conversations(in: selectedFolder, cursor: .first, filter: mode.serverFilter)
                guard generation == listGeneration else { return }
                if let key = currentListKey {
                    if listSnapshots[key] == nil, listSnapshots.count >= Self.snapshotLimit { listSnapshots.removeAll() }
                    listSnapshots[key] = ListSnapshot(conversations: page.conversations, nextCursor: page.nextCursor, totalInView: page.totalInView, loadedAt: Date())
                }
                nextCursor = page.nextCursor
                totalInView = page.totalInView
                listShowsFolderPage = true
                conversations = page.conversations
            }
            staleList = nil
            selectedIDs = selectedIDs.intersection(conversations.map(\.id))
        } catch {
            guard generation == listGeneration, !MailCancellation.isCancellation(error) else { return }
            if activeSearch == nil, let key = currentListKey, let snapshot = listSnapshots[key] {
                // Keep what was loaded before and say how old it is, instead of an empty list.
                nextCursor = snapshot.nextCursor
                totalInView = snapshot.totalInView
                listShowsFolderPage = true
                conversations = snapshot.conversations
                staleList = MailStaleListNotice(loadedAt: snapshot.loadedAt, isConnectionError: MailConnectivity.isConnectionError(error))
                return
            }
            staleList = nil
            listShowsFolderPage = false
            conversations = []
            nextCursor = nil
            listError = error.localizedDescription
        }
    }

    var canLoadMore: Bool {
        isSearching ? searchMoreAvailable && conversations.count < OWAMailPayloads.searchResultsCap : nextCursor != nil
    }

    func loadMore() async {
        guard canLoadMore, !isLoadingList else { return }
        let generation = listGeneration
        isLoadingList = true
        defer { if generation == listGeneration { isLoadingList = false } }
        do {
            if let activeSearch {
                let count = min(OWAMailPayloads.pageSize * 2, OWAMailPayloads.searchResultsCap - conversations.count)
                let page = try await service.search(activeSearch, offset: conversations.count, count: count)
                guard generation == listGeneration else { return }
                apply(searchPage: page, appending: true)
            } else if let cursor = nextCursor {
                let page = try await service.conversations(in: selectedFolder, cursor: cursor, filter: mode.serverFilter)
                guard generation == listGeneration else { return }
                let known = Set(conversations.map(\.id))
                // The cursor first: the list change writes the snapshot, and it must carry this
                // page's cursor, not the previous one.
                nextCursor = page.nextCursor
                conversations += page.conversations.filter { !known.contains($0.id) }
            }
        } catch {
            show(error)
        }
    }

    func isPending(_ action: MailPendingAction) -> Bool { pending.contains(action) }

    /// Runs `work` with `action` marked pending; a second call while it runs does nothing.
    private func whilePending(_ action: MailPendingAction, _ work: () async -> Void) async {
        guard pending.insert(action).inserted else { return }
        defer { pending.remove(action) }
        await work()
    }

    func refresh() async {
        await whilePending(.refresh) { await reloadAll() }
    }

    private func reloadAll() async {
        await loadFolders()
        await reloadList()
        if let id = selectedConversationID { await openConversation(id, reload: true) }
    }

    // MARK: - Selection

    /// A click on a row: plain opens it, ⌘ adds or removes it from the picked set, ⇧ picks the
    /// range from the open conversation.
    func click(_ conversation: MailConversationSummary, modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.command) {
            var picked = selectedIDs
            if picked.isEmpty, let open = selectedConversationID { picked.insert(open) }
            if picked.contains(conversation.id) { picked.remove(conversation.id) } else { picked.insert(conversation.id) }
            selectedIDs = picked
            return
        }
        if modifiers.contains(.shift), let anchor = selectedConversationID ?? selectedIDs.first {
            let order = orderedVisibleIDs
            if let from = order.firstIndex(of: anchor), let to = order.firstIndex(of: conversation.id) {
                selectedIDs = Set(order[min(from, to)...max(from, to)])
                return
            }
        }
        selectedIDs = []
        Task { await openConversation(conversation.id) }
    }

    func isPicked(_ id: String) -> Bool {
        selectedIDs.count > 1 ? selectedIDs.contains(id) : selectedConversationID == id
    }

    /// What list actions apply to: the picked set, else the open conversation.
    var actionTargets: [MailConversationSummary] {
        let ids = selectedIDs.count > 1 ? selectedIDs : Set([selectedConversationID].compactMap { $0 })
        return conversations.filter { ids.contains($0.id) }
    }

    func selectAllVisible() {
        selectedIDs = Set(orderedVisibleIDs)
    }

    /// ↑/↓: opens the previous or next conversation in list order.
    func moveFocus(by step: Int) {
        let order = orderedVisibleIDs
        guard !order.isEmpty else { return }
        let index = selectedConversationID.flatMap { order.firstIndex(of: $0) } ?? (step > 0 ? -1 : order.count)
        let next = min(max(index + step, 0), order.count - 1)
        selectedIDs = []
        Task { await openConversation(order[next]) }
    }

    // MARK: - List actions

    // List actions show at once and go back if the server refuses: waiting for Exchange left a
    // click looking like nothing happened for a second or two.

    func markRead(_ targets: [MailConversationSummary], _ isRead: Bool) async {
        guard !targets.isEmpty else { return }
        let ids = Set(targets.map(\.id))
        let before = Dictionary(conversations.filter { ids.contains($0.id) }.map { ($0.id, $0.unreadCount) }, uniquingKeysWith: { first, _ in first })
        let threadBefore = thread.flatMap { ids.contains($0.id) ? $0 : nil }
        var deltas: [String: Int] = [:]
        for target in targets {
            let after = isRead ? 0 : max(1, target.unreadCount)
            if let folderID = folderID(of: target.parentFolderID) { deltas[folderID, default: 0] += after - target.unreadCount }
        }
        applyUnreadDeltas(deltas)
        conversations = conversations.map { conversation in
            guard ids.contains(conversation.id) else { return conversation }
            return conversation.with(unreadCount: isRead ? 0 : max(1, conversation.unreadCount))
        }
        if let thread, ids.contains(thread.id) {
            self.thread = MailThread(id: thread.id, messages: thread.messages.map { $0.with(isRead: isRead) }, totalMessageCount: thread.totalMessageCount)
        }
        do {
            try await service.setRead(conversations: targets, isRead)
        } catch {
            applyUnreadDeltas(deltas.mapValues { -$0 })
            conversations = conversations.map { conversation in
                before[conversation.id].map { conversation.with(unreadCount: $0) } ?? conversation
            }
            if let threadBefore, let thread, thread.id == threadBefore.id {
                let wasRead = Dictionary(threadBefore.messages.map { ($0.id, $0.isRead) }, uniquingKeysWith: { first, _ in first })
                self.thread = MailThread(
                    id: thread.id,
                    messages: thread.messages.map { message in wasRead[message.id].map { message.with(isRead: $0) } ?? message },
                    totalMessageCount: thread.totalMessageCount
                )
            }
            show(error)
        }
    }

    func flag(_ targets: [MailConversationSummary], _ flagged: Bool) async {
        guard !targets.isEmpty else { return }
        let ids = Set(targets.map(\.id))
        let before = Dictionary(conversations.filter { ids.contains($0.id) }.map { ($0.id, $0.isFlagged) }, uniquingKeysWith: { first, _ in first })
        conversations = conversations.map { ids.contains($0.id) ? $0.with(isFlagged: flagged) : $0 }
        do {
            try await service.setFlag(conversations: targets, flagged)
        } catch {
            conversations = conversations.map { conversation in
                before[conversation.id].map { conversation.with(isFlagged: $0) } ?? conversation
            }
            show(error)
        }
    }

    func move(_ targets: [MailConversationSummary], to folder: MailFolderRef) async {
        guard !targets.isEmpty else { return }
        let ids = Set(targets.map(\.id))
        let order = orderedVisibleIDs
        let nextID = order.first { !ids.contains($0) && (order.firstIndex(of: $0) ?? 0) > (order.firstIndex { ids.contains($0) } ?? 0) }
        let removed = conversations.enumerated().filter { ids.contains($0.element.id) }
        let openID = selectedConversationID.flatMap { ids.contains($0) ? $0 : nil }
        withAnimation(.easeInOut(duration: 0.15)) {
            conversations.removeAll { ids.contains($0.id) }
            selectedIDs = []
        }
        if openID != nil {
            clearSelection()
            if let nextID { Task { await openConversation(nextID) } }
        }
        do {
            try await service.move(conversations: targets, to: folder)
            await loadFolders()
        } catch {
            // Back in their places. The conversation that was open comes back too, unless the
            // user has opened another one since.
            withAnimation(.easeInOut(duration: 0.15)) {
                for (offset, conversation) in removed where !conversations.contains(where: { $0.id == conversation.id }) {
                    conversations.insert(conversation, at: min(offset, conversations.count))
                }
            }
            if let openID, selectedConversationID == nil || selectedConversationID == nextID {
                Task { await openConversation(openID) }
            }
            show(error)
        }
    }

    func markAllRead() async {
        bulkProgress = 0
        defer { bulkProgress = nil }
        do {
            try await service.markAllRead(in: selectedFolder) { [weak self] count in
                Task { @MainActor in self?.bulkProgress = count }
            }
            conversations = conversations.map { $0.with(unreadCount: 0) }
            await loadFolders()
            await service.checkInbox()
        } catch {
            show(error)
        }
    }

    // MARK: - Thread

    func openConversation(_ id: String, reload: Bool = false) async {
        markReadTask?.cancel()
        if selectedConversationID != id {
            selectedConversationID = id
            thread = nil
            expandedMessageIDs = []
            readerDocuments = [:]
            readerDocumentBuilds = [:]
        }
        threadError = nil
        isLoadingThread = true
        defer { isLoadingThread = false }
        do {
            let loaded = try await service.thread(id, useCache: !reload, includingDeleted: selectedFolder == .distinguished(.deleteditems))
            guard selectedConversationID == id else { return }
            thread = loaded
            var expanded = Set(loaded.messages.filter { !$0.isRead }.map(\.id))
            if let newest = loaded.messages.first { expanded.insert(newest.id) }
            expandedMessageIDs.formUnion(expanded)
            loadInlineImages(for: loaded.messages.filter { expandedMessageIDs.contains($0.id) })
            scheduleMarkRead(loaded)
        } catch {
            guard selectedConversationID == id, !MailCancellation.isCancellation(error) else { return }
            threadError = error.localizedDescription
        }
    }

    func toggleExpanded(_ message: MailMessage) {
        if expandedMessageIDs.contains(message.id) {
            expandedMessageIDs.remove(message.id)
        } else {
            expandedMessageIDs.insert(message.id)
            loadInlineImages(for: [message])
        }
    }

    /// Loads the inline images of messages being opened. A conversation does not always list
    /// the inline attachments of its older messages, so a body that refers to a `cid:` image its
    /// message does not list is read again on its own, attachments included. Finding those
    /// references scans the whole body: done off the main thread, as the reader's document is.
    private func loadInlineImages(for messages: [MailMessage]) {
        for message in messages where inlineImages[message.id] == nil {
            inlineImages[message.id] = [:]
            let body = fullBodies[message.id] ?? message.bodyHTML ?? ""
            Task {
                let references = await Task.detached(priority: .userInitiated) {
                    MailHTMLDocument.inlineImageReferences(in: body)
                }.value
                let listed = Set(message.attachments.filter(\.isInline).compactMap { $0.contentID?.lowercased() })
                guard !references.isEmpty || !listed.isEmpty else {
                    // Nothing to load: left unmarked, so a later look (at the full text with the
                    // quoted history, say) scans again.
                    if inlineImages[message.id]?.isEmpty ?? false { inlineImages[message.id] = nil }
                    return
                }
                var source = message
                if references.contains(where: { !listed.contains($0) }), let full = try? await service.fullMessage(message.ref) {
                    source = full
                }
                inlineImages[message.id] = await service.inlineImages(for: source)
            }
        }
    }

    /// Marks the unread messages of the open thread as read once it has been open long enough.
    /// Only the wait is cancellable: a request already sent is left to finish, or the cancelled
    /// request would come back as an error and the message stay unread on the server.
    private func scheduleMarkRead(_ thread: MailThread) {
        guard let delay = service.settings.markReadPolicy.delay else { return }
        let unread = thread.messages.filter { !$0.isRead && !$0.isDraft }
        guard !unread.isEmpty else { return }
        markReadTask = Task { @MainActor [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled, let self, self.selectedConversationID == thread.id else { return }
            Task { @MainActor [weak self] in
                for message in unread { await self?.setRead(message, true) }
            }
        }
    }

    func setRead(_ message: MailMessage, _ isRead: Bool) async {
        let before = current(message)
        let changes = before.isRead != isRead
        if changes { adjustUnread(for: before, isRead: isRead) }
        await updateMessage(message, apply: { $0.with(isRead: isRead) }, revert: { $0.with(isRead: before.isRead) }, onFailure: {
            if changes { self.adjustUnread(for: before, isRead: !isRead) }
        }) {
            try await self.service.setRead($0, isRead)
        }
    }

    /// The folder counter and the list row of a message that turned read or unread.
    private func adjustUnread(for message: MailMessage, isRead: Bool) {
        if let folderID = folderID(of: message.parentFolderID) {
            applyUnreadDeltas([folderID: isRead ? -1 : 1])
        }
        if let conversationID = message.conversationID ?? selectedConversationID,
           let index = conversations.firstIndex(where: { $0.id == conversationID }) {
            let old = conversations[index]
            conversations[index] = old.with(unreadCount: max(0, old.unreadCount + (isRead ? -1 : 1)))
        }
    }

    func setFlag(_ message: MailMessage, _ flagged: Bool) async {
        let before = current(message)
        await updateMessage(message, apply: { $0.with(isFlagged: flagged) }, revert: { $0.with(isFlagged: before.isFlagged) }) {
            try await self.service.setFlag($0, flagged)
        }
    }

    func toggleCategory(_ name: String, on message: MailMessage) async {
        // From what is on screen: a second toggle right after the first builds on it.
        let before = current(message)
        var categories = before.categories
        if let index = categories.firstIndex(of: name) { categories.remove(at: index) } else { categories.append(name) }
        await setCategories(categories, on: message, before: before)
    }

    func clearCategories(_ message: MailMessage) async {
        await setCategories([], on: message, before: current(message))
    }

    private func setCategories(_ categories: [String], on message: MailMessage, before: MailMessage) async {
        await updateMessage(message, apply: { $0.with(categories: categories) }, revert: { $0.with(categories: before.categories) }) {
            try await self.service.setCategories($0, categories)
        }
    }

    /// The message as the reader shows it, with the latest change key the server gave for it.
    private func current(_ message: MailMessage) -> MailMessage {
        let shown = thread?.messages.first { $0.id == message.id } ?? message
        return messageConfirmed[message.id].map { shown.with(ref: $0.ref) } ?? shown
    }

    /// Shows the change at once, then sends it. Changes of one message go one after another:
    /// each needs the change key the server answered the previous one with, so a second click
    /// waits for the first instead of being lost. On a failure only this change is taken back.
    ///
    /// A request is made from the message as the server last confirmed it, plus its own change —
    /// never from the screen, which may already show later changes still on their way: the
    /// service caches what it is given, and a refused change must not stay in that copy.
    private func updateMessage(
        _ message: MailMessage,
        apply: @escaping (MailMessage) -> MailMessage,
        revert: @escaping (MailMessage) -> MailMessage,
        onFailure: @escaping () -> Void = {},
        _ request: @escaping (MailMessage) async throws -> MailMessage
    ) async {
        let id = message.id
        // The first change of a run: what is on screen is what the server holds.
        if messageConfirmed[id] == nil { messageConfirmed[id] = current(message) }
        replace(apply(current(message)))
        let previous = messageChanges[id]
        let change = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            do {
                let answered = try await request(self.messageConfirmed[id] ?? message)
                self.messageConfirmed[id] = answered
                // Only the change key: the fields on screen may already carry a later change.
                self.replace(self.current(message))
            } catch {
                self.replace(revert(self.current(message)))
                onFailure()
                self.show(error)
            }
        }
        messageChanges[id] = change
        await change.value
        if messageChanges[id] == change {
            messageChanges[id] = nil
            messageConfirmed[id] = nil
        }
    }

    /// Moves the whole open thread to a folder; "delete" goes to Deleted Items.
    func moveThread(to folder: MailFolderRef) async {
        if let summary = conversations.first(where: { $0.id == thread?.id }) {
            await move([summary], to: folder)
            return
        }
        guard let thread else { return }
        do {
            try await service.move(thread.messages, to: folder)
            conversations.removeAll { $0.id == thread.id }
            clearSelection()
            await loadFolders()
        } catch {
            show(error)
        }
    }

    // MARK: - Folder counters

    /// The folder a conversation or message sits in: its own, else the one the list shows.
    private func folderID(of parentFolderID: String?) -> String? {
        if let parentFolderID, folders.contains(where: { $0.id == parentFolderID }) { return parentFolderID }
        return isSearching ? nil : selectedFolderInfo?.id
    }

    /// Counters move at once; a few seconds after the last change the server's own counts
    /// replace them (one small request for a whole run of reading).
    private func applyUnreadDeltas(_ deltas: [String: Int]) {
        guard deltas.values.contains(where: { $0 != 0 }) else { return }
        service.adjustFolderUnread(deltas)
        folders = service.folders
        countsTask?.cancel()
        countsTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, let self else { return }
            await self.service.checkInbox()
            // The check also wakes `syncFolderCounts`; whichever runs second skips its request.
            await self.service.refreshFolderCounts(minInterval: 3)
            self.folders = self.service.folders
        }
    }

    /// The periodic inbox check ran: bring the sidebar counters up to date with it.
    func syncFolderCounts() async {
        await service.refreshFolderCounts()
        folders = service.folders
    }

    private func replace(_ message: MailMessage) {
        guard let thread else { return }
        let messages = thread.messages.map { $0.id == message.id || $0.ref.id == message.ref.id ? message : $0 }
        self.thread = MailThread(id: thread.id, messages: messages, totalMessageCount: thread.totalMessageCount)
    }

    func loadFullBody(_ message: MailMessage) async {
        await whilePending(.fullBody(message.id)) {
            do {
                let full = try await service.fullMessage(message.ref)
                fullBodies[message.id] = full.bodyHTML ?? ""
                // The quoted history may refer to pictures the short text did not.
                loadInlineImages(for: [full])
            } catch {
                show(error)
            }
        }
    }

    // MARK: - Meetings in mail

    func meetingResponse(for message: MailMessage) -> MeetingResponseType? {
        meetingAnswers[message.id] ?? service.meetingResponse(for: message)
    }

    func respond(to message: MailMessage, _ action: MeetingResponseAction) async {
        await whilePending(.meetingResponse(message.id)) {
            do {
                if try await service.respond(to: message, action: action) {
                    meetingAnswers[message.id] = switch action {
                    case .accept: .accepted
                    case .tentative: .tentative
                    case .decline: .declined
                    }
                } else {
                    openInOWA(message)
                }
            } catch {
                show(error)
            }
        }
    }

    /// Fetches the blocked remote images of one message over a plain session (no cookies, no
    /// OWA credentials) and shows them inline.
    func loadRemoteImages(for message: MailMessage) {
        let html = fullBodies[message.id] ?? message.bodyHTML ?? ""
        let sources = Array(MailHTMLDocument.remoteImageSources(in: html).prefix(MailRemoteImageLoader.maxImages))
        guard !sources.isEmpty, pending.insert(.remoteImages(message.id)).inserted else { return }
        Task {
            remoteImages[message.id] = await MailRemoteImageLoader.load(sources)
            pending.remove(.remoteImages(message.id))
        }
    }

    /// The message's reader document, or nil until its first build is ready. A build starts here
    /// when none matches the body and images at hand; meanwhile an older build stays on screen.
    func readerDocument(for message: MailMessage) -> MailReaderDocument? {
        let body = fullBodies[message.id] ?? message.bodyHTML ?? ""
        let inline = inlineImages[message.id] ?? [:]
        let remote = remoteImages[message.id] ?? [:]
        let key = MailReaderDocument.Key(
            bodyLength: body.utf8.count,
            isFull: fullBodies[message.id] != nil,
            inlineImages: inline.count,
            remoteImages: remote.count
        )
        let current = readerDocuments[message.id]
        if current?.key != key, readerDocumentBuilds[message.id] != key {
            readerDocumentBuilds[message.id] = key
            let id = message.id
            Task { [weak self] in
                let built = await Task.detached(priority: .userInitiated) {
                    MailReaderDocument(
                        key: key,
                        html: MailHTMLDocument.document(body: body, inlineImages: inline, remoteImages: remote),
                        hasRemoteImages: MailHTMLDocument.hasRemoteImages(body),
                        isVisuallyEmpty: MailHTMLDocument.isVisuallyEmpty(body)
                    )
                }.value
                // A newer build was asked for meanwhile, or another thread opened: drop this one.
                guard let self, self.readerDocumentBuilds[id] == key else { return }
                self.readerDocumentBuilds[id] = nil
                self.readerDocuments[id] = built
            }
        }
        return current
    }

    func document(for message: MailMessage) -> String {
        MailHTMLDocument.document(
            body: fullBodies[message.id] ?? message.bodyHTML ?? "",
            inlineImages: inlineImages[message.id] ?? [:],
            remoteImages: remoteImages[message.id] ?? [:]
        )
    }

    // MARK: - Search

    func submitSearch() async {
        let query = searchFilters.query(currentFolder: selectedFolder)
        guard !query.isEmpty else {
            clearSearch()
            await reloadList()
            return
        }
        activeSearch = query
        clearSelection()
        await reloadList()
    }

    func clearSearch() {
        guard activeSearch != nil || !searchFilters.text.isEmpty else { return }
        // Search results stay on screen until the folder reloads: not a folder page meanwhile.
        listShowsFolderPage = false
        activeSearch = nil
        searchTerms = []
        refiners = []
        searchMoreAvailable = false
        searchFilters = MailSearchFilters()
        clearSelection()
        service.endSearch()
    }

    func applyRefiner(_ refiner: MailSearchRefiner) async {
        switch refiner {
        case .sender: if !searchFilters.from.contains(refiner) { searchFilters.from.append(refiner) }
        case .folder: searchFilters.folderRefiner = refiner
        case .attachments(let has, _): searchFilters.hasAttachments = has
        }
        await submitSearch()
    }

    private func apply(searchPage page: MailSearchPage, appending: Bool) {
        listShowsFolderPage = false
        if appending {
            let known = Set(conversations.map(\.id))
            conversations += page.conversations.filter { !known.contains($0.id) }
        } else {
            conversations = page.conversations
            searchTerms = page.searchTerms
            refiners = page.refiners
        }
        searchMoreAvailable = page.moreAvailable
        nextCursor = nil
        totalInView = nil
    }

    func folderName(for id: String?) -> String? {
        guard let id else { return nil }
        return folders.first { $0.id == id }?.displayName
    }

    // MARK: - Compose and links

    func compose(_ kind: MailOutgoing.Kind, from message: MailMessage, ownAddress: String?) {
        service.compose(MailComposeDraftBuilder.request(kind, from: message, ownAddress: ownAddress))
    }

    func openInOWA(_ message: MailMessage) {
        guard let account = service.account, let url = MailOWALink.url(serverURL: account.serverURL, itemID: message.ref.id) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Attachments

    func save(_ attachment: MailAttachmentInfo) async {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = MailAttachmentFiles.safeFileName(attachment.name)
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        await whilePending(.attachment(attachment.id)) {
            do {
                let data = try await service.attachment(attachment)
                try data.write(to: url, options: .atomic)
                MailAttachmentFiles.markQuarantined(url)
            } catch {
                show(error)
            }
        }
    }

    /// Opens an image of the message in Quick Look at full size when `url` is one of the
    /// reader's zoom links (`MailHTMLDocument.zoomURL`); `false` for any other link.
    func openImage(_ url: URL, in message: MailMessage) -> Bool {
        guard let source = MailHTMLDocument.zoomSource(from: url) else { return false }
        let inline = inlineImages[message.id] ?? [:]
        let cid = MailHTMLDocument.contentID(fromSource: source)
        guard let image = cid.flatMap({ inline[$0] ?? inline[$0.lowercased()] }) ?? remoteImages[message.id]?[source] else {
            return true  // a zoom link with nothing behind it goes nowhere
        }
        do {
            let directory = try MailAttachmentFiles.preparePreviewDirectory()
            let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let fileExtension = UTType(mimeType: image.type)?.preferredFilenameExtension ?? "png"
            let file = folder.appendingPathComponent("image." + fileExtension)
            try image.data.write(to: file, options: .atomic)
            MailAttachmentFiles.markQuarantined(file)
            MailQuickLook.shared.show(file)
        } catch {
            show(error)
        }
        return true
    }

    func preview(_ attachment: MailAttachmentInfo) async {
        await whilePending(.attachment(attachment.id)) {
            do {
                let data = try await service.attachment(attachment)
                let directory = try MailAttachmentFiles.preparePreviewDirectory()
                let url = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let file = url.appendingPathComponent(MailAttachmentFiles.safeFileName(attachment.name))
                try data.write(to: file, options: .atomic)
                MailAttachmentFiles.markQuarantined(file)
                MailQuickLook.shared.show(file)
            } catch {
                show(error)
            }
        }
    }
}

/// Prefills the compose window for a reply, a reply-all or a forward.
enum MailComposeDraftBuilder {
    static func request(_ kind: MailOutgoing.Kind, from message: MailMessage, ownAddress: String?) -> MailComposeRequest {
        let own = ownAddress?.lowercased()
        let sender = message.from?.email
        func isOwn(_ address: String?) -> Bool { address != nil && address?.lowercased() == own }
        var to: [String] = []
        var cc: [String] = []
        switch kind {
        case .reply:
            if let sender, !isOwn(sender) { to = [sender] } else { to = message.to.compactMap(\.email) }
        case .replyAll:
            let others = message.to.compactMap(\.email).filter { !isOwn($0) }
            if let sender, !isOwn(sender) { to = [sender] + others } else { to = others }
            cc = message.cc.compactMap(\.email).filter { !isOwn($0) }
        case .forward, .new:
            break
        }
        let unique: ([String]) -> [String] = { list in
            var seen = Set<String>()
            return list.filter { seen.insert($0.lowercased()).inserted }
        }
        to = unique(to)
        cc = unique(cc).filter { address in !to.contains { $0.caseInsensitiveCompare(address) == .orderedSame } }
        return MailComposeRequest(kind: kind, original: message, to: to, cc: cc, subject: defaultSubject(kind, original: message.subject), body: "")
    }

    static func defaultSubject(_ kind: MailOutgoing.Kind, original: String) -> String {
        switch kind {
        case .new: original
        case .reply, .replyAll: original.lowercased().hasPrefix("re:") ? original : "RE: \(original)"
        case .forward: original.lowercased().hasPrefix("fw:") ? original : "FW: \(original)"
        }
    }
}
