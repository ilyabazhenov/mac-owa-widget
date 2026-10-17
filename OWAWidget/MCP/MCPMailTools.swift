import Foundation
import OWAWidgetMCPShared

/// The MCP mail tools: reading folders, lists, threads and search results, and `prepare_mail`,
/// which sends only after the user confirms in OWA Widget's own panel.
///
/// Every request goes through `MCPAccessGuard` (budget, concurrency, blocked sync, circuit
/// breaker), straight to the account's provider: the mail window's switch does not gate these,
/// the MCP mail switches do. Nothing here changes the mailbox — no read marks, no moves, no
/// search history — except the message the user confirms.
@MainActor
final class MCPMailTools {
    nonisolated static let readToolNames: Set<String> = ["get_mail_digest", "list_mail_folders", "list_mail", "search_mail", "get_mail_thread", "get_mail_message"]
    nonisolated static let sendToolName = "prepare_mail"
    nonisolated static var toolNames: Set<String> { readToolNames.union([sendToolName]) }

    static let maxMessageCharacters = 8_000
    static let maxThreadCharacters = 40_000
    static let maxFullMessageCharacters = 16_000
    static let maxOutgoingBodyCharacters = 20_000
    static let maxRecipients = 50
    static let handleLimit = 2_000
    static let folderCacheLifetime: TimeInterval = 10 * 60
    static let sendsPerHour = 5
    static let duplicateWindow: TimeInterval = 10 * 60

    static let disabledMessage = "Mail access for AI assistants is turned off in OWA Widget (Settings → AI (MCP) → Mail). Ask the user to turn it on."
    static let sendDisabledMessage = "Preparing emails is turned off in OWA Widget (Settings → AI (MCP) → Mail). Nothing was sent. Ask the user to turn it on."

    struct ToolError: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    private let calendarService: CalendarService
    private let accessGuard: MCPAccessGuard
    private let confirmer: MCPMailConfirming
    private let handOff: (MailComposeRequest) -> Void
    private let canHandOff: () -> Bool
    private let isEnabled: () -> Bool
    private let canSend: () -> Bool
    private let clock: () -> Date
    private let timeZoneProvider: () -> TimeZone
    private let confirmationTimeout: TimeInterval

    private var handles: [String: String] = [:]
    private var handleOrder: [String] = []
    private var folderCache: [UUID: (folders: [MailFolder], date: Date)] = [:]
    private var ownAddresses: [UUID: (email: String?, retryAfter: Date)] = [:]
    private var recentSends: [String: (date: Date, result: [String: JSONValue])] = [:]
    private var sendTimes: [Date] = []
    private var isConfirming = false

    init(
        calendarService: CalendarService,
        accessGuard: MCPAccessGuard,
        confirmer: MCPMailConfirming? = nil,
        handOff: @escaping (MailComposeRequest) -> Void = { _ in },
        canHandOff: @escaping () -> Bool = { false },
        isEnabled: @escaping () -> Bool = { false },
        canSend: @escaping () -> Bool = { false },
        confirmationTimeout: TimeInterval = MCPCalendarTools.confirmationTimeout,
        clock: @escaping () -> Date = { Date() },
        timeZone: @escaping () -> TimeZone = { AppTimeZone.zone }
    ) {
        self.calendarService = calendarService
        self.accessGuard = accessGuard
        self.confirmer = confirmer ?? MCPMailConfirmationController()
        self.handOff = handOff
        self.canHandOff = canHandOff
        self.isEnabled = isEnabled
        self.canSend = canSend
        self.confirmationTimeout = confirmationTimeout
        self.clock = clock
        self.timeZoneProvider = timeZone
    }

    func call(name: String, arguments: [String: JSONValue], client: String?) async -> MCPToolResult {
        guard isEnabled() else { return .failure(Self.disabledMessage) }
        let coder = MCPDateCoder(timeZone: timeZoneProvider())
        do {
            switch name {
            case "get_mail_digest": return try await mailDigest(arguments, coder)
            case "list_mail_folders": return try await listFolders(arguments, coder)
            case "list_mail": return try await listMail(arguments, coder)
            case "search_mail": return try await searchMail(arguments, coder)
            case "get_mail_thread": return try await getThread(arguments, coder)
            case "get_mail_message": return try await getMessage(arguments, coder)
            case "prepare_mail": return try await prepareMail(arguments, coder, client: client)
            default: return .failure("Unknown tool: \(name)")
            }
        } catch let error as ToolError {
            return .failure(error.message)
        } catch MailError.notFound {
            return .failure("Not found. The message may have been moved or deleted (moving changes its id) — list or search again.")
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    // MARK: - Plumbing

    /// One provider request, counted against the shared budget and reported to the breaker.
    private func request<T: Sendable>(
        _ account: CalendarAccount,
        cost: Int = 1,
        context: String,
        _ operation: @Sendable (any MailProvider) async throws -> T
    ) async throws -> T {
        if let denial = accessGuard.permitRequest(count: cost) { throw ToolError(denial.message) }
        guard let provider = calendarService.mailProvider(accountID: account.id) else {
            throw ToolError("This account's mailbox is not available right now (no password saved, or OWA Widget is still starting).")
        }
        await accessGuard.acquireSlot()
        defer { accessGuard.releaseSlot() }
        do {
            return try await operation(provider)
        } catch {
            accessGuard.report(error, context: context)
            throw error
        }
    }

    private func mailAccount(_ arguments: [String: JSONValue]) throws -> CalendarAccount {
        let accounts = calendarService.mailAccounts
        if let raw = arguments["account_id"]?.stringValue {
            guard let id = UUID(uuidString: raw), let account = accounts.first(where: { $0.id == id }) else {
                throw ToolError("Unknown `account_id`, or that account has no Exchange mailbox; take one from get_status")
            }
            return account
        }
        switch accounts.count {
        case 1: return accounts[0]
        case 0: throw ToolError("No Exchange account is connected in OWA Widget")
        default: throw ToolError("Several Exchange accounts are connected: pass `account_id` from get_status")
        }
    }

    /// A short, stable handle for a long Exchange id (12 hex characters).
    func handle(_ id: String) -> String {
        let short = MCPShortHash.hex(id, bytes: 6)
        if handles[short] == nil {
            handleOrder.append(short)
            if handleOrder.count > Self.handleLimit {
                handles[handleOrder.removeFirst()] = nil
            }
        }
        handles[short] = id
        return short
    }

    /// The full id behind a handle; a full id is accepted as is.
    func resolve(_ handle: String) -> String? {
        if handle.count > 20 { return handle }
        return handles[handle.lowercased()]
    }

    private func requiredID(_ arguments: [String: JSONValue], _ key: String, from: String) throws -> String {
        guard let value = arguments[key]?.stringValue?.trimmingCharacters(in: .whitespaces), !value.isEmpty else {
            throw ToolError("`\(key)` is required (take it from \(from))")
        }
        guard let id = resolve(value) else {
            throw ToolError("Unknown `\(key)` \(value). Ids are remembered only while OWA Widget runs: call \(from) again.")
        }
        return id
    }

    private func optionalInt(_ arguments: [String: JSONValue], _ key: String, range: ClosedRange<Int>) throws -> Int? {
        guard let value = arguments[key], value != .null else { return nil }
        guard let number = value.intValue, range.contains(number) else {
            throw ToolError("`\(key)` must be an integer from \(range.lowerBound) to \(range.upperBound)")
        }
        return number
    }

    private func optionalDate(_ arguments: [String: JSONValue], _ key: String, _ coder: MCPDateCoder, bound: MCPDateCoder.Bound) throws -> Date? {
        guard let text = arguments[key]?.stringValue, !text.isEmpty else { return nil }
        guard let date = coder.parse(text, as: bound) else { throw ToolError("`\(key)` must be a date (YYYY-MM-DD) or an ISO 8601 date-time") }
        return date
    }

    private func stringList(_ arguments: [String: JSONValue], _ key: String) throws -> [String] {
        guard let value = arguments[key], value != .null else { return [] }
        if let single = value.stringValue { return [single.trimmingCharacters(in: .whitespaces)].filter { !$0.isEmpty } }
        guard let array = value.arrayValue else { throw ToolError("`\(key)` must be an array of strings") }
        return try array.map { item in
            guard let text = item.stringValue?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { throw ToolError("`\(key)` must contain strings") }
            return text
        }
    }

    private func commonFields(_ coder: MCPDateCoder, _ account: CalendarAccount) -> [String: JSONValue] {
        [
            "now": .string(coder.string(clock())),
            "timezone": .string(coder.timeZone.identifier),
            "account_id": .string(account.id.uuidString),
        ]
    }

    private func folders(_ account: CalendarAccount, load: Bool) async throws -> [MailFolder]? {
        if let cached = folderCache[account.id], clock().timeIntervalSince(cached.date) < Self.folderCacheLifetime {
            return cached.folders
        }
        guard load else { return folderCache[account.id]?.folders }
        let loaded = try await request(account, context: "mcp.mail.folders") { try await $0.mailFolders() }
        let ordered = MailFolderTree.ordered(loaded)
        folderCache[account.id] = (ordered, clock())
        return ordered
    }

    private static let systemFolderNames: [String: MailDistinguishedFolder] = [
        "inbox": .inbox, "sent": .sentitems, "sentitems": .sentitems, "sent_items": .sentitems,
        "drafts": .drafts, "deleted": .deleteditems, "deleteditems": .deleteditems, "deleted_items": .deleteditems,
        "trash": .deleteditems, "junk": .junkemail, "junkemail": .junkemail, "spam": .junkemail, "archive": .archive,
    ]

    private func folderRef(_ raw: String?, _ account: CalendarAccount) async throws -> MailFolderRef {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return .distinguished(.inbox) }
        if let system = Self.systemFolderNames[raw.lowercased()] { return .distinguished(system) }
        if let id = resolve(raw) { return .id(id) }
        if let list = try await folders(account, load: true),
           let match = list.first(where: { $0.displayName.caseInsensitiveCompare(raw) == .orderedSame }) {
            return match.distinguished.map { .distinguished($0) } ?? .id(match.id)
        }
        throw ToolError("Unknown folder `\(raw)`. Use inbox, sent, drafts, deleted, junk, archive, a folder name or a folder_id from list_mail_folders.")
    }

    private func ownAddress(_ account: CalendarAccount) async -> String? {
        if let cached = ownAddresses[account.id], cached.email != nil || clock() < cached.retryAfter { return cached.email }
        guard accessGuard.permitRequest() == nil else { return nil }
        await accessGuard.acquireSlot()
        defer { accessGuard.releaseSlot() }
        do {
            let email = try await calendarService.ownEmail(accountID: account.id)
            ownAddresses[account.id] = (email, clock().addingTimeInterval(10 * 60))
            return email
        } catch {
            accessGuard.report(error, context: "mcp.mail.ownEmail")
            ownAddresses[account.id] = (nil, clock().addingTimeInterval(60))
            return nil
        }
    }

    static func isExternal(_ email: String?, ownDomain: String?) -> Bool? {
        guard let email, let ownDomain, let at = email.lastIndex(of: "@") else { return nil }
        let domain = email[email.index(after: at)...].lowercased()
        return domain != ownDomain && !domain.hasSuffix("." + ownDomain)
    }

    private static func domain(_ email: String?) -> String? {
        email.flatMap { $0.split(separator: "@").last.map { String($0).lowercased() } }
    }

    // MARK: - JSON

    private func conversationJSON(_ conversation: MailConversationSummary, _ coder: MCPDateCoder, folderNames: [String: String] = [:]) -> JSONValue {
        var fields: [String: JSONValue] = [
            "thread_id": .string(handle(conversation.id)),
            "subject": .string(conversation.topic),
            "from": .array(conversation.senders.map(JSONValue.string)),
            "last_received": .optional(conversation.lastDelivery.map(coder.string)),
            "messages": .int(Int64(conversation.messageCount)),
            "unread": .int(Int64(conversation.unreadCount)),
            "has_attachments": .bool(conversation.hasAttachments),
            "preview": .string(conversation.preview),
        ]
        if !conversation.recipients.isEmpty { fields["to"] = .array(conversation.recipients.map(JSONValue.string)) }
        if conversation.importance != .normal { fields["importance"] = .string(conversation.importance.rawValue.lowercased()) }
        if conversation.isFlagged { fields["flagged"] = true }
        if !conversation.categories.isEmpty { fields["categories"] = .array(conversation.categories.map(JSONValue.string)) }
        if conversation.isProtected { fields["protected"] = true }
        if conversation.isAutomated { fields["from_system"] = true }
        if conversation.userHasReplied { fields["you_replied"] = true }
        if let folder = conversation.parentFolderID {
            fields["folder"] = .optional(folderNames[folder])
            fields["folder_id"] = .string(handle(folder))
        }
        return .object(fields)
    }

    private func addressJSON(_ address: MailAddress, ownDomain: String?) -> JSONValue {
        var fields: [String: JSONValue] = ["name": .string(address.displayName), "email": .optional(address.email)]
        if let external = Self.isExternal(address.email, ownDomain: ownDomain), external { fields["external"] = true }
        return .object(fields)
    }

    private static func kindName(_ kind: MailItemKind) -> String {
        switch kind {
        case .note: "message"
        case .meetingRequest: "meeting_request"
        case .meetingResponse: "meeting_response"
        case .meetingCancellation: "meeting_cancellation"
        case .protected: "protected"
        case .archived: "archived"
        case .other: "other"
        }
    }

    /// One message; `budget` is what is left of the characters this answer may still carry.
    private func messageJSON(_ message: MailMessage, _ coder: MCPDateCoder, ownDomain: String?, characterLimit: Int, budget: inout Int) -> JSONValue {
        var fields: [String: JSONValue] = [
            "message_id": .string(handle(message.ref.id)),
            "subject": .string(message.subject),
            "from": message.from.map { addressJSON($0, ownDomain: ownDomain) } ?? .null,
            "to": .array(message.to.map { addressJSON($0, ownDomain: ownDomain) }),
            "received": .optional(message.received.map(coder.string)),
            "is_read": .bool(message.isRead),
            "kind": .string(Self.kindName(message.kind)),
        ]
        if !message.cc.isEmpty { fields["cc"] = .array(message.cc.map { addressJSON($0, ownDomain: ownDomain) }) }
        if !message.bcc.isEmpty { fields["bcc"] = .array(message.bcc.map { addressJSON($0, ownDomain: ownDomain) }) }
        if message.hiddenRecipientCount > 0 { fields["more_recipients"] = .int(Int64(message.hiddenRecipientCount)) }
        if message.importance != .normal { fields["importance"] = .string(message.importance.rawValue.lowercased()) }
        if message.isFlagged { fields["flagged"] = true }
        if !message.categories.isEmpty { fields["categories"] = .array(message.categories.map(JSONValue.string)) }
        let attachments = message.visibleAttachments
        if !attachments.isEmpty {
            fields["attachments"] = .array(attachments.map { attachment in
                var item: [String: JSONValue] = [
                    "name": .string(attachment.name),
                    "type": .string(attachment.contentType),
                    "size": .int(Int64(attachment.size)),
                ]
                if attachment.isItemAttachment { item["attached_message"] = true }
                return .object(item)
            })
        }
        if let meeting = message.meeting {
            fields["meeting"] = .object([
                "start": .optional(meeting.start.map(coder.string)),
                "end": .optional(meeting.end.map(coder.string)),
                "location": .optional(meeting.location),
            ])
        }
        switch message.kind {
        case .protected:
            fields["text"] = .null
            fields["text_unavailable"] = "The message is encrypted (IRM or S/MIME); only OWA can open it."
        case .archived:
            fields["text"] = .string(String(MailHTMLDocument.plainText(message.bodyHTML).prefix(1_000)))
            fields["text_unavailable"] = "The message is in the Enterprise Vault archive; this is only its stub. The full text opens in OWA."
        default:
            let text = MailHTMLDocument.plainText(message.bodyHTML)
            let allowed = max(0, min(characterLimit, budget))
            if text.count > allowed {
                fields["text"] = .string(String(text.prefix(allowed)))
                fields["text_truncated"] = true
                budget -= allowed
            } else {
                fields["text"] = .string(text)
                budget -= text.count
            }
        }
        return .object(fields)
    }

    // MARK: - Tools

    /// What needs attention, in three requests: the inbox count, the first page of unread
    /// conversations, and the first page of the inbox for "awaiting your reply".
    private func mailDigest(_ arguments: [String: JSONValue], _ coder: MCPDateCoder) async throws -> MCPToolResult {
        let account = try mailAccount(arguments)
        let limit = try optionalInt(arguments, "limit", range: 1...30) ?? 10
        let days = try optionalInt(arguments, "awaiting_days", range: 1...30) ?? 7
        let counts = try await request(account, context: "mcp.mail.digest") { try await $0.mailFolderCounts([.distinguished(.inbox)]) }
        let unreadPage = try await request(account, context: "mcp.mail.digest") {
            try await $0.mailConversations(in: .distinguished(.inbox), cursor: .first, filter: .unread)
        }
        let recentPage = try await request(account, context: "mcp.mail.digest") {
            try await $0.mailConversations(in: .distinguished(.inbox), cursor: .first, filter: .all)
        }
        let unread = unreadPage.conversations.filter(\.isUnread)
        let people = unread.filter { !$0.isAutomated }
        var systems: [String: (count: Int, unread: Int, latest: MailConversationSummary)] = [:]
        for conversation in unread where conversation.isAutomated {
            let entry = systems[conversation.primarySender]
            systems[conversation.primarySender] = (
                (entry?.count ?? 0) + 1, (entry?.unread ?? 0) + conversation.unreadCount, entry?.latest ?? conversation
            )
        }
        let since = clock().addingTimeInterval(-Double(days) * 86_400)
        let awaiting = recentPage.conversations.filter {
            !$0.isAutomated && !$0.userHasReplied && ($0.lastDelivery ?? .distantPast) >= since
        }

        var result = commonFields(coder, account)
        result["inbox_unread"] = .int(Int64(counts.first?.unreadCount ?? unread.count))
        result["unread_from_people"] = .array(people.prefix(limit).map { conversationJSON($0, coder) })
        result["awaiting_reply"] = .array(awaiting.prefix(limit).map { conversationJSON($0, coder) })
        result["unread_from_systems"] = .array(systems.sorted { $0.value.unread > $1.value.unread }.prefix(15).map { sender, entry in
            .object([
                "sender": .string(sender),
                "conversations": .int(Int64(entry.count)),
                "unread": .int(Int64(entry.unread)),
                "latest_subject": .string(entry.latest.topic),
                "latest_thread_id": .string(handle(entry.latest.id)),
            ])
        })
        if unreadPage.nextCursor != nil {
            result["note"] = "Only the newest page of unread mail was looked at; call list_mail with unread_only for more."
        }
        result["how_classified"] = .string("`from_system` means the sender looks like a system (CI, tracker, no-reply, a name without a surname); `awaiting_reply` lists people's conversations of the last \(days) days in which the user has not written yet. Both are heuristics: say so if it matters.")
        return .success(result)
    }

    private func listFolders(_ arguments: [String: JSONValue], _ coder: MCPDateCoder) async throws -> MCPToolResult {
        let account = try mailAccount(arguments)
        let list = try await folders(account, load: true) ?? []
        var result = commonFields(coder, account)
        result["folders"] = .array(list.filter { $0.distinguished != .msgfolderroot }.map { folder in
            var fields: [String: JSONValue] = [
                "folder_id": .string(handle(folder.id)),
                "name": .string(folder.displayName),
                "unread": .int(Int64(folder.unreadCount)),
                "total": .int(Int64(folder.totalCount)),
            ]
            if let system = folder.distinguishedID { fields["system"] = .string(system) }
            if let parent = folder.parentID, list.contains(where: { $0.id == parent && $0.distinguished != .msgfolderroot }) {
                fields["parent_id"] = .string(handle(parent))
            }
            return .object(fields)
        })
        return .success(result)
    }

    private func listMail(_ arguments: [String: JSONValue], _ coder: MCPDateCoder) async throws -> MCPToolResult {
        let account = try mailAccount(arguments)
        let folder = try await folderRef(arguments["folder"]?.stringValue, account)
        let unreadOnly = arguments["unread_only"]?.boolValue ?? false
        let limit = try optionalInt(arguments, "limit", range: 1...50) ?? 20
        let only = arguments["only"]?.stringValue
        guard only == nil || only == "people" || only == "awaiting_reply" else {
            throw ToolError("`only` must be people or awaiting_reply")
        }
        let keep: (MailConversationSummary) -> Bool = { conversation in
            switch only {
            case "people": !conversation.isAutomated
            case "awaiting_reply": !conversation.isAutomated && !conversation.userHasReplied
            default: true
            }
        }
        let since = try optionalDate(arguments, "since", coder, bound: .start)
        var cursor = MailListCursor.first
        if let raw = arguments["cursor"]?.stringValue, !raw.isEmpty {
            guard let key = resolve(raw) else { throw ToolError("Unknown `cursor`: call list_mail without it") }
            cursor = .after(instanceKey: key)
        }

        var collected: [MailConversationSummary] = []
        var next: MailListCursor? = cursor
        var reachedSince = false
        var total: Int?
        // At most two pages per call: the model asks again with `next_cursor` for more.
        for _ in 0..<2 {
            guard let page = next, collected.count < limit, !reachedSince else { break }
            let filter: MailListFilter = unreadOnly ? .unread : .all
            let loaded = try await request(account, context: "mcp.mail.list") { try await $0.mailConversations(in: folder, cursor: page, filter: filter) }
            total = total ?? loaded.totalInView
            for conversation in loaded.conversations {
                if let since, let date = conversation.lastDelivery, date < since {
                    reachedSince = true
                    break
                }
                if collected.count < limit, keep(conversation) { collected.append(conversation) }
            }
            next = loaded.nextCursor
        }

        var result = commonFields(coder, account)
        let names = (try? await folders(account, load: false))??.reduce(into: [String: String]()) { $0[$1.id] = $1.displayName } ?? [:]
        result["threads"] = .array(collected.map { conversationJSON($0, coder, folderNames: names) })
        if let total { result["total_in_folder"] = .int(Int64(total)) }
        if !reachedSince, let last = collected.last?.instanceKey, next != nil || collected.count == limit {
            result["next_cursor"] = .string(handle(last))
        }
        return .success(result)
    }

    private func searchMail(_ arguments: [String: JSONValue], _ coder: MCPDateCoder) async throws -> MCPToolResult {
        let account = try mailAccount(arguments)
        var query = MailSearchQuery(text: arguments["query"]?.stringValue ?? "")
        query.from = try stringList(arguments, "from")
        for address in query.from where !MCPCalendarTools.isEmailAddress(address) {
            throw ToolError("`from` takes email addresses (find them with find_people); got `\(address)`")
        }
        if let has = arguments["has_attachments"]?.boolValue { query.hasAttachments = has }
        query.receivedFrom = try optionalDate(arguments, "since", coder, bound: .start)
        query.receivedTo = try optionalDate(arguments, "until", coder, bound: .end)
        if let raw = arguments["folder"]?.stringValue, !raw.isEmpty {
            switch try await folderRef(raw, account) {
            case .distinguished(let name): query.scope = .distinguished(name)
            case .id(let id): query.scope = .folder(id: id)
            }
        }
        guard !query.isEmpty else { throw ToolError("Give `query` or at least one filter (`from`, `since`, `until`, `has_attachments`)") }
        let limit = try optionalInt(arguments, "limit", range: 1...50) ?? 25
        var offset = 0
        if let raw = arguments["cursor"]?.stringValue, !raw.isEmpty {
            guard let value = Int(raw), value > 0, value < OWAMailPayloads.searchResultsCap else { throw ToolError("Unknown `cursor`: search again without it") }
            offset = value
        }
        let count = min(limit, OWAMailPayloads.searchResultsCap - offset)
        let finalQuery = query
        let startOffset = offset
        // Start the session, the search itself, and possibly ending an older session.
        let page = try await request(account, cost: 2, context: "mcp.mail.search") { try await $0.mailSearch(finalQuery, offset: startOffset, count: count) }

        var result = commonFields(coder, account)
        let names = (try? await folders(account, load: false))??.reduce(into: [String: String]()) { $0[$1.id] = $1.displayName } ?? [:]
        result["threads"] = .array(page.conversations.map { conversationJSON($0, coder, folderNames: names) })
        let nextOffset = offset + page.conversations.count
        result["more_available"] = .bool(page.moreAvailable && nextOffset < OWAMailPayloads.searchResultsCap)
        if page.moreAvailable, nextOffset < OWAMailPayloads.searchResultsCap, !page.conversations.isEmpty {
            result["next_cursor"] = .string(String(nextOffset))
        }
        if page.moreAvailable, nextOffset >= OWAMailPayloads.searchResultsCap {
            result["note"] = .string("Exchange returns at most \(OWAMailPayloads.searchResultsCap) results per search: narrow it with `from`, `since`/`until` or `folder`.")
        }
        if !page.searchTerms.isEmpty { result["matched_terms"] = .array(page.searchTerms.map(JSONValue.string)) }
        let suggestions: [JSONValue] = page.refiners.compactMap { refiner in
            switch refiner {
            case .sender(let name, let email, let count):
                return ["type": "from", "name": .string(name), "email": .string(email), "count": .int(Int64(count))]
            case .folder(_, let folderID, let count):
                guard let folderID else { return nil }
                return ["type": "folder", "folder_id": .string(handle(folderID)), "name": .optional(names[folderID]), "count": .int(Int64(count))]
            case .attachments(let has, let count):
                return ["type": "has_attachments", "value": .bool(has), "count": .int(Int64(count))]
            }
        }
        if !suggestions.isEmpty { result["suggested_filters"] = .array(suggestions) }
        return .success(result)
    }

    private func getThread(_ arguments: [String: JSONValue], _ coder: MCPDateCoder) async throws -> MCPToolResult {
        let account = try mailAccount(arguments)
        let id = try requiredID(arguments, "thread_id", from: "list_mail or search_mail")
        let maxMessages = try optionalInt(arguments, "max_messages", range: 1...20) ?? 10
        let thread = try await request(account, context: "mcp.mail.thread") { try await $0.mailThread(conversationID: id, ignoringFolders: []) }
        let ownDomain = Self.domain(await ownAddress(account))
        var budget = Self.maxThreadCharacters
        var result = commonFields(coder, account)
        result["thread_id"] = .string(handle(thread.id))
        result["subject"] = .string(thread.topic)
        result["total_messages"] = .int(Int64(thread.totalMessageCount))
        result["messages"] = .array(thread.messages.prefix(maxMessages).map {
            messageJSON($0, coder, ownDomain: ownDomain, characterLimit: Self.maxMessageCharacters, budget: &budget)
        })
        if thread.messages.count > maxMessages || thread.totalMessageCount > thread.messages.count {
            result["note"] = "Newest messages first; older ones are not included. Each message's `text` is only what it added, without the quoted history: get_mail_message returns the full text."
        } else {
            result["note"] = "Newest messages first. Each `text` is only what that message added, without the quoted history."
        }
        if ownDomain == nil { result["external_check"] = "unavailable: the user's own address is unknown, so `external` is not marked" }
        return .success(result)
    }

    private func getMessage(_ arguments: [String: JSONValue], _ coder: MCPDateCoder) async throws -> MCPToolResult {
        let account = try mailAccount(arguments)
        let id = try requiredID(arguments, "message_id", from: "get_mail_thread")
        let message = try await request(account, context: "mcp.mail.message") { try await $0.mailMessage(MailItemRef(id: id, changeKey: nil)) }
        let ownDomain = Self.domain(await ownAddress(account))
        var budget = Self.maxFullMessageCharacters
        var result = commonFields(coder, account)
        result["message"] = messageJSON(message, coder, ownDomain: ownDomain, characterLimit: Self.maxFullMessageCharacters, budget: &budget)
        if let conversation = message.conversationID { result["thread_id"] = .string(handle(conversation)) }
        return .success(result)
    }

    // MARK: - prepare_mail

    private func prepareMail(_ arguments: [String: JSONValue], _ coder: MCPDateCoder, client: String?) async throws -> MCPToolResult {
        guard canSend() else { return .failure(Self.sendDisabledMessage) }
        let account = try mailAccount(arguments)
        guard let kind = arguments["kind"]?.stringValue.flatMap({ raw -> MailOutgoing.Kind? in
            switch raw {
            case "new": .new
            case "reply": .reply
            case "reply_all": .replyAll
            case "forward": .forward
            default: nil
            }
        }) else { throw ToolError("`kind` must be new, reply, reply_all or forward") }

        var to = try stringList(arguments, "to")
        var cc = try stringList(arguments, "cc")
        let subjectArgument = arguments["subject"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let body = (arguments["body"]?.stringValue ?? "").replacingOccurrences(of: "\r\n", with: "\n")
        guard body.count <= Self.maxOutgoingBodyCharacters else { throw ToolError("`body` is limited to \(Self.maxOutgoingBodyCharacters) characters") }
        guard subjectArgument.count <= 255 else { throw ToolError("`subject` is limited to 255 characters") }
        for (name, text) in [("subject", subjectArgument), ("body", body)] where MCPMeetingTextPolicy.containsBidiControls(text) {
            throw ToolError("`\(name)` contains bidirectional control characters (U+202A–U+202E, U+2066–U+2069), which make text display differently from what is sent. Remove them.")
        }

        var original: MailMessage?
        if kind != .new {
            let id = try requiredID(arguments, "message_id", from: "get_mail_thread")
            original = try await request(account, context: "mcp.mail.original") { try await $0.mailMessage(MailItemRef(id: id, changeKey: nil)) }
        }
        let own = await ownAddress(account)
        let ownDomain = Self.domain(own)
        if let original, to.isEmpty, cc.isEmpty, kind != .forward {
            let defaults = MailComposeDraftBuilder.request(kind, from: original, ownAddress: own)
            to = defaults.to
            cc = defaults.cc
        }
        guard !to.isEmpty else { throw ToolError("`to` is required for \(kind == .forward ? "a forward" : "a new message") (addresses from find_people)") }
        if kind == .new, subjectArgument.isEmpty { throw ToolError("`subject` is required for a new message") }
        let all = to + cc
        guard all.count <= Self.maxRecipients else { throw ToolError("At most \(Self.maxRecipients) recipients") }
        for address in all where !(MCPCalendarTools.isEmailAddress(address) && MCPMeetingTextPolicy.isPlainASCIIAddress(address)) {
            throw ToolError("`\(address)` is not a plain email address. Take addresses from find_people or the thread.")
        }
        cc = cc.filter { address in !to.contains { $0.caseInsensitiveCompare(address) == .orderedSame } }

        let shownSubject = subjectArgument.isEmpty
            ? MailComposeDraftBuilder.defaultSubject(kind, original: original?.subject ?? "")
            : subjectArgument
        let outgoing = MailOutgoing(kind: kind, reference: original?.ref, to: to, cc: cc, subject: subjectArgument, body: body)

        let key = [account.id.uuidString, "\(kind)", original?.ref.id ?? "", to.map { $0.lowercased() }.sorted().joined(separator: ","),
                   cc.map { $0.lowercased() }.sorted().joined(separator: ","), subjectArgument, body].joined(separator: "|")
        let now = clock()
        recentSends = recentSends.filter { now.timeIntervalSince($0.value.date) < Self.duplicateWindow }
        if let earlier = recentSends[key] {
            var result = earlier.result
            result["duplicate"] = true
            result["note"] = "This exact email was already handled a few minutes ago; nothing new was sent."
            return .success(result)
        }
        sendTimes = sendTimes.filter { now.timeIntervalSince($0) < 3600 }
        guard sendTimes.count < Self.sendsPerHour else {
            return .failure("OWA Widget allows at most \(Self.sendsPerHour) emails per hour from AI assistants. Nothing was sent; the user can write it in OWA Widget's compose window.")
        }
        guard !isConfirming else {
            return .failure("Another email is waiting for the user's answer in OWA Widget. Wait for that call to finish.")
        }
        if let reason = MCPAccessGuard.blockReason(calendarService.syncStatus) { return .failure(reason) }
        isConfirming = true
        defer { isConfirming = false }

        let known = Set(([original?.from?.email] + (original?.to ?? []).map(\.email) + (original?.cc ?? []).map(\.email)).compactMap { $0?.lowercased() })
        let recipient = { (email: String) in
            MCPMailProposal.Recipient(
                email: email,
                isExternal: Self.isExternal(email, ownDomain: ownDomain) ?? false,
                isNew: kind != .new && !known.contains(email.lowercased())
            )
        }
        let proposal = MCPMailProposal(
            kind: kind,
            to: to.map(recipient),
            cc: cc.map(recipient),
            subject: shownSubject,
            body: body,
            original: original.map { MCPMailProposal.Original(from: $0.from?.displayName ?? "", subject: $0.subject, received: $0.received) },
            forwardedAttachments: kind == .forward ? (original?.visibleAttachments.map(\.name) ?? []) : [],
            client: client ?? "",
            externalCheckAvailable: ownDomain != nil,
            canOpenDraft: canHandOff()
        )

        switch await confirmer.confirm(proposal, timeout: confirmationTimeout) {
        case .confirmed:
            break
        case .rejected:
            return .failure("The user declined in OWA Widget. Nothing was sent; do not retry unless the user asks.")
        case .handedOff where proposal.canOpenDraft:
            handOff(MailComposeRequest(kind: kind, original: original, to: to, cc: cc, subject: shownSubject, body: body))
            var result = commonFields(coder, account)
            result["sent"] = false
            result["handed_off"] = true
            result["note"] = "The user opened this email in OWA Widget's compose window to change and send it themselves. Nothing has been sent yet; do not call prepare_mail for it again."
            recentSends[key] = (now, result)
            return .success(result)
        case .handedOff:
            // The panel offered no draft button; treat a stray hand-off as a refusal.
            return .failure("The user declined in OWA Widget. Nothing was sent; do not retry unless the user asks.")
        case .timedOut:
            return .failure("The user did not answer in OWA Widget within \(Int(confirmationTimeout)) seconds. Nothing was sent; ask the user whether to try again.")
        case .cancelled:
            return .failure("The request was cancelled. Nothing was sent.")
        }

        // Past "Send" the request finishes even if the client cancels: a half-known outcome is
        // the worst one for an email.
        guard accessGuard.permitRequest() == nil, let provider = calendarService.mailProvider(accountID: account.id) else {
            return .failure("OWA Widget could not reach Exchange right now. Nothing was sent.")
        }
        let guardRef = accessGuard
        let sending = Task { @MainActor in
            await guardRef.acquireSlot()
            defer { guardRef.releaseSlot() }
            return try await provider.mailSend(outgoing)
        }
        do {
            _ = try await sending.value
        } catch {
            accessGuard.report(error, context: "mcp.mail.send")
            MCPDebugLog.log("prepare_mail send failed: \(error.localizedDescription)")
            return .failure("Exchange did not confirm the email: \(error.localizedDescription). It may still have been sent: check the Sent folder (list_mail folder=sent) before trying again.")
        }
        sendTimes.append(now)
        var result = commonFields(coder, account)
        result["sent"] = true
        result["kind"] = .string(arguments["kind"]?.stringValue ?? "")
        result["to"] = .array(to.map(JSONValue.string))
        result["cc"] = .array(cc.map(JSONValue.string))
        result["subject"] = .string(shownSubject)
        result["note"] = "Sent by Exchange; a copy is in the Sent folder."
        recentSends[key] = (now, result)
        return .success(result)
    }
}
