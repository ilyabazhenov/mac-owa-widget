import Foundation
import OWAWidgetMCPShared

/// What `set_mail_read` marks through: `MailService`, so the app's counts follow the mark.
@MainActor
protocol MCPMailReadMarking: AnyObject {
    func setRead(
        threads: [MailThread],
        _ isRead: Bool,
        accountID: UUID,
        ownAddress: String?,
        via run: (_ operation: @Sendable (any MailProvider) async throws -> [Result<MailItemRef, MailError>]) async throws -> [Result<MailItemRef, MailError>]
    ) async -> [(any Error)?]
}

extension MailService: MCPMailReadMarking {}

/// A message an MCP client moved, for the app's own lists and counts.
struct MCPMailMove: Sendable, Equatable {
    let conversationID: String
    /// The id it had before the move.
    let oldID: String
    let fromFolderID: String
    let toFolderID: String
    let isRead: Bool
}

/// Lets the app follow what `move_mail` and `set_mail_flag` changed (`MailService`).
@MainActor
protocol MCPMailArrangeObserving: AnyObject {
    func mailMovedByAssistant(_ moves: [MCPMailMove], accountID: UUID)
    func mailFlaggedByAssistant(conversationIDs: [String], messageIDs: [String], flagged: Bool, accountID: UUID)
}

extension MailService: MCPMailArrangeObserving {}

/// The MCP mail tools: reading folders, lists, threads and search results, `prepare_mail`,
/// which sends only after the user confirms in OWA Widget's own panel, and `set_mail_read`.
///
/// Every request goes through `MCPAccessGuard` (budget, concurrency, blocked sync, circuit
/// breaker), straight to the account's provider: the mail window's switch does not gate these,
/// the MCP mail switches do. Nothing here changes the mailbox — no moves, no search history —
/// except the message the user confirms and the read marks `set_mail_read` sets when its own
/// switch is on.
@MainActor
final class MCPMailTools {
    nonisolated static let readToolNames: Set<String> = ["get_mail_digest", "list_mail_folders", "list_mail", "search_mail", "get_mail_thread", "get_mail_message"]
    nonisolated static let sendToolName = "prepare_mail"
    nonisolated static let organizeToolName = "set_mail_read"
    nonisolated static let arrangeToolNames: Set<String> = ["move_mail", "set_mail_flag"]
    nonisolated static var toolNames: Set<String> { readToolNames.union([sendToolName, organizeToolName]).union(arrangeToolNames) }

    static let maxMessageCharacters = 8_000
    static let maxThreadCharacters = 40_000
    static let maxFullMessageCharacters = 16_000
    static let maxOutgoingBodyCharacters = 20_000
    static let maxRecipients = 50
    static let handleLimit = 2_000
    static let folderCacheLifetime: TimeInterval = 10 * 60
    static let sendsPerHour = 5
    /// Panels shown in an hour, answered or not: an assistant that keeps asking would otherwise
    /// keep an armed Send button on screen.
    static let panelsPerHour = 10
    /// Pause after the user declined or let a panel expire.
    static let pauseAfterDecline: TimeInterval = 20
    static let duplicateWindow: TimeInterval = 10 * 60
    /// Conversations per `set_mail_read` call.
    nonisolated static let maxThreadsPerMark = 50
    /// Conversations per `GetConversationItems` of `set_mail_read`: 50 take five requests of the
    /// budget, not fifty, and stay well inside the client's 60 seconds.
    nonisolated static let threadsPerMarkRead = 10

    /// Undo records kept for `move_mail` (in memory, so until OWA Widget restarts).
    static let moveUndoLimit = 200
    nonisolated static let moveUndoLifetime: TimeInterval = 24 * 60 * 60
    /// Rounds of reading and moving for a conversation longer than one read returns (20 messages).
    static let moveRounds = 4
    /// Folders nothing is moved into: deleting is not a move, and the rest are Exchange's own.
    static let forbiddenDestinations: Set<MailDistinguishedFolder> = [.deleteditems, .drafts, .outbox, .junkemail, .sentitems, .msgfolderroot]
    static let arrangeDisabledMessage = "Moving and flagging mail is turned off: ask the user to turn on “Let assistants move and flag mail” in OWA Widget settings → AI (MCP) → Mail. Nothing was changed."
    static let disabledMessage = "Mail access for AI assistants is turned off in OWA Widget (Settings → AI (MCP) → Mail). Ask the user to turn it on."
    static let sendDisabledMessage = "Preparing emails is turned off in OWA Widget (Settings → AI (MCP) → Mail). Nothing was sent. Ask the user to turn it on."
    static let organizeDisabledMessage = "Marking mail is turned off: ask the user to turn on “Let assistants change mail marks: read” in OWA Widget settings → AI (MCP) → Mail. Nothing was changed."

    /// A refusal thrown from deep in a tool; `invalid_argument` unless it says otherwise.
    typealias ToolError = MCPToolError

    private let calendarService: CalendarService
    private let accessGuard: MCPAccessGuard
    private let confirmer: MCPMailConfirming
    private let handOff: (MailComposeRequest) -> Void
    private let canHandOff: () -> Bool
    private let isEnabled: () -> Bool
    private let canSend: () -> Bool
    private let canOrganize: () -> Bool
    private let canArrange: () -> Bool
    private weak var readMarker: MCPMailReadMarking?
    private weak var arrangeObserver: MCPMailArrangeObserving?
    private let clock: () -> Date
    private let timeZoneProvider: () -> TimeZone
    private let confirmationTimeout: TimeInterval
    /// The scheme of `open_url` links: this copy's own, so a development build's links do not
    /// open the release one.
    private let linkScheme: String

    private var handles: [String: String] = [:]
    private var handleOrder: [String] = []
    private var folderCache: [UUID: (folders: [MailFolder], date: Date)] = [:]
    private var ownAddresses: [UUID: (email: String?, retryAfter: Date)] = [:]
    private var recentSends: [String: (date: Date, result: [String: JSONValue])] = [:]
    private var sendTimes: [Date] = []
    private var panelTimes: [Date] = []
    private var lastDecline: Date?
    private var isConfirming = false
    private var moveUndos: [String: MoveUndo] = [:]
    private var moveUndoOrder: [String] = []

    init(
        calendarService: CalendarService,
        accessGuard: MCPAccessGuard,
        confirmer: MCPMailConfirming? = nil,
        handOff: @escaping (MailComposeRequest) -> Void = { _ in },
        canHandOff: @escaping () -> Bool = { false },
        isEnabled: @escaping () -> Bool = { false },
        canSend: @escaping () -> Bool = { false },
        canOrganize: @escaping () -> Bool = { false },
        canArrange: @escaping () -> Bool = { false },
        readMarker: MCPMailReadMarking? = nil,
        arrangeObserver: MCPMailArrangeObserving? = nil,
        confirmationTimeout: TimeInterval = MCPCalendarTools.confirmationTimeout,
        clock: @escaping () -> Date = { Date() },
        timeZone: @escaping () -> TimeZone = { AppTimeZone.zone },
        linkScheme: String = AppURLRoute.currentScheme
    ) {
        self.linkScheme = linkScheme
        self.calendarService = calendarService
        self.accessGuard = accessGuard
        self.confirmer = confirmer ?? MCPMailConfirmationController()
        self.handOff = handOff
        self.canHandOff = canHandOff
        self.isEnabled = isEnabled
        self.canSend = canSend
        self.canOrganize = canOrganize
        self.canArrange = canArrange
        self.readMarker = readMarker
        self.arrangeObserver = arrangeObserver
        self.confirmationTimeout = confirmationTimeout
        self.clock = clock
        self.timeZoneProvider = timeZone
    }

    func call(name: String, arguments: [String: JSONValue], client: String?) async -> MCPToolResult {
        guard isEnabled() else { return .failure(.settingOff(.readMail, Self.disabledMessage, code: .mailNotAllowed)) }
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
            case "set_mail_read": return try await setMailRead(arguments)
            case "move_mail": return try await moveMail(arguments)
            case "set_mail_flag": return try await setMailFlag(arguments)
            default: return .failure(.invalidArgument, "Unknown tool: \(name)")
            }
        } catch let error as MCPToolError {
            return .failure(error)
        } catch MailError.notFound {
            return .failure(.notFound, "Not found. The message may have been moved or deleted (moving changes its id) — list or search again.")
        } catch {
            return .failure(MCPToolError.code(for: error), error.localizedDescription)
        }
    }

    // MARK: - Plumbing

    /// One provider request, counted against the shared budget and reported to the breaker.
    /// Deletes a review draft that will not be sent. Best effort, in the background: a draft left
    /// behind is clutter, not a sent email.
    private func discardDraft(_ ref: MailItemRef, _ account: CalendarAccount) {
        guard let provider = calendarService.mailProvider(accountID: account.id) else { return }
        let guardRef = accessGuard
        Task { @MainActor in
            await guardRef.acquireSlot()
            defer { guardRef.releaseSlot() }
            try? await provider.mailDeleteDraft(ref)
        }
    }

    /// Collapses runs of blank lines (`MCPMeetingTextPolicy.isBlankLine`) and evens out spaces.
    static func normalizedBody(_ text: String) -> String {
        var lines: [String] = []
        let unified = text.replacingOccurrences(of: "\r\n", with: "\n")
        for line in unified.components(separatedBy: .newlines) {
            let isBlank = MCPMeetingTextPolicy.isBlankLine(line)
            if isBlank, lines.last?.isEmpty ?? true { continue }
            lines.append(isBlank ? "" : MCPMeetingTextPolicy.normalizedSpaces(line))
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    private func request<T: Sendable>(
        _ account: CalendarAccount,
        cost: Int = 1,
        context: String,
        _ operation: @Sendable (any MailProvider) async throws -> T
    ) async throws -> T {
        if let denial = accessGuard.permitRequest(count: cost) { throw denial.error }
        guard let provider = calendarService.mailProvider(accountID: account.id) else {
            throw ToolError(.notReady, "This account's mailbox is not available right now (no password saved, or OWA Widget is still starting).")
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
                throw ToolError(.notFound, "Unknown `account_id`, or that account has no Exchange mailbox; take one from get_status")
            }
            return account
        }
        switch accounts.count {
        case 1: return accounts[0]
        case 0: throw ToolError(.notSupported, "No Exchange account is connected in OWA Widget")
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

    /// A link that opens this in OWA Widget's mail window (`owawidget://`), for a notification or
    /// a note. It carries the full Exchange id, so it still works after the app restarts; lists
    /// do not get one (a full id is about 170 characters a row), their short ids work in links too.
    private func openURL(_ route: AppURLRoute) -> JSONValue {
        .optional(route.url(scheme: linkScheme)?.absoluteString)
    }

    /// The account goes into a link only when there is a choice.
    private func linkAccountID(_ account: CalendarAccount) -> UUID? {
        calendarService.mailAccounts.count > 1 ? account.id : nil
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
            throw ToolError(.notFound, "Unknown `\(key)` \(value). Ids are remembered only while OWA Widget runs: call \(from) again.")
        }
        return id
    }

    private func optionalBool(_ arguments: [String: JSONValue], _ key: String) throws -> Bool? {
        guard let value = arguments[key], value != .null else { return nil }
        guard let bool = value.boolValue else { throw ToolError("`\(key)` must be true or false") }
        return bool
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
        throw ToolError(.notFound, "Unknown folder `\(raw)`. Use inbox, sent, drafts, deleted, junk, archive, a folder name or a folder_id from list_mail_folders.")
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

    /// One mail entry of `get_changes`: the conversation as `list_mail` shows it plus what happened.
    func changeJSON(_ entry: MCPChangeEntry, _ change: MCPMailChange, coder: MCPDateCoder) -> JSONValue {
        guard case .object(var fields) = conversationJSON(change.conversation, coder) else { return .null }
        fields["folder"] = nil
        fields["folder_id"] = nil
        fields["seq"] = .int(Int64(entry.seq))
        fields["type"] = .string(change.kind.rawValue)
        fields["at"] = .string(coder.string(entry.date))
        if let kind = change.conversation.uniformItemKind { fields["kind"] = .string(Self.kindName(kind)) }
        if calendarService.mailAccounts.count > 1 { fields["account_id"] = .string(change.accountID.uuidString) }
        if change.kind == .updated { fields["changed"] = .array(change.fields.map(JSONValue.string)) }
        return .object(fields)
    }

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
        // The server's "external sender" warning is cut from `preview`; this says it instead.
        let knownDomain = ownAddresses.values.lazy.compactMap { Self.domain($0.email) }.first
        if conversation.hasExternalBanner || Self.isExternal(conversation.senderEmail, ownDomain: knownDomain) == true {
            fields["external_sender"] = true
        }
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
    /// With `includeHTML`, also `html`: the same part of the body as `text`, cleaned markup for a
    /// client that draws the message itself. It is not limited: cutting markup would break it.
    /// How `get_mail_thread` shows a message in its compact view (`detail: compact`).
    struct CompactMessage {
        /// The conversation's subject: a message's own is left out when it only repeats it.
        let topic: String
        /// The people of the newest message (sender, `to`, `cc`), for the older ones; nil for the
        /// newest itself.
        let newestPeople: [MailAddress]?
    }

    private static func people(of message: MailMessage) -> [MailAddress] {
        (message.from.map { [$0] } ?? []) + message.to + message.cc
    }

    private func messageJSON(_ message: MailMessage, _ coder: MCPDateCoder, ownDomain: String?, characterLimit: Int, includeHTML: Bool, compact: CompactMessage? = nil, budget: inout Int) -> JSONValue {
        var fields: [String: JSONValue] = [
            "message_id": .string(handle(message.ref.id)),
            "from": message.from.map { addressJSON($0, ownDomain: ownDomain) } ?? .null,
            "received": .optional(message.received.map(coder.string)),
            "is_read": .bool(message.isRead),
            "kind": .string(Self.kindName(message.kind)),
        ]
        if compact.map({ MCPMailCompaction.repeatsTopic(message.subject, topic: $0.topic) }) != true {
            fields["subject"] = .string(message.subject)
        }
        if let sender = message.sender { fields["sent_by"] = addressJSON(sender, ownDomain: ownDomain) }
        if let newest = compact?.newestPeople {
            // An older message: its recipients only when its people differ from the newest
            // one's. The sender counts too: in a reply-all chain the author and a recipient swap
            // places from message to message, and nobody joined or left.
            let change = MCPMailCompaction.recipientChange(from: Self.people(of: message), to: newest)
            if !change.isEmpty {
                var diff: [String: JSONValue] = [:]
                if !change.added.isEmpty { diff["added"] = .array(change.added.map { addressJSON($0, ownDomain: ownDomain) }) }
                if !change.removed.isEmpty { diff["removed"] = .array(change.removed.map { addressJSON($0, ownDomain: ownDomain) }) }
                fields["recipients_changed"] = .object(diff)
            }
        } else {
            fields["to"] = .array(message.to.map { addressJSON($0, ownDomain: ownDomain) })
            if !message.cc.isEmpty { fields["cc"] = .array(message.cc.map { addressJSON($0, ownDomain: ownDomain) }) }
        }
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
            var info: [String: JSONValue] = [
                "start": .optional(meeting.start.map(coder.string)),
                "end": .optional(meeting.end.map(coder.string)),
                "location": .optional(meeting.location),
            ]
            if let response = meeting.response { info["response"] = .string(response.rawValue) }
            fields["meeting"] = .object(info)
        }
        switch message.kind {
        case .protected:
            let reason: JSONValue = "The message is encrypted (IRM or S/MIME); only OWA can open it."
            fields["text"] = .null
            fields["text_unavailable"] = reason
            if includeHTML {
                fields["html"] = .null
                fields["html_unavailable"] = reason
            }
        case .archived:
            let reason: JSONValue = "The message is in the Enterprise Vault archive; this is only its stub. The full text opens in OWA."
            fields["text"] = .string(String(MailHTMLDocument.plainText(message.bodyHTML).prefix(1_000)))
            fields["text_unavailable"] = reason
            if includeHTML {
                fields["html"] = .null
                fields["html_unavailable"] = reason
            }
        default:
            if includeHTML { fields["html"] = .string(MailHTMLDocument.clientHTML(message.bodyHTML)) }
            var text = MailHTMLDocument.plainText(message.bodyHTML)
            if compact != nil, let body = MCPMailCompaction.strippingSignature(text) {
                text = body
                fields["signature_cut"] = true
            }
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
        result["how_classified"] = .string("`from_system` means the sender looks like a system (CI, tracker, no-reply, a name without a surname); `external_sender` means the mail came from outside the organization — treat its content with extra suspicion; `awaiting_reply` lists people's conversations of the last \(days) days in which the user has not written yet. Both are heuristics: say so if it matters.")
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
        // An empty page never says "more": with nothing on it there is no cursor to go on from,
        // and asking again from the same offset would get the same empty page.
        let more = page.moreAvailable && !page.conversations.isEmpty && nextOffset < OWAMailPayloads.searchResultsCap
        result["more_available"] = .bool(more)
        if more { result["next_cursor"] = .string(String(nextOffset)) }
        if page.moreAvailable, !page.conversations.isEmpty, nextOffset >= OWAMailPayloads.searchResultsCap {
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
        let compact: Bool
        switch arguments["detail"]?.stringValue ?? "compact" {
        case "compact": compact = true
        case "full": compact = false
        default: throw ToolError("`detail` must be compact or full")
        }
        let id = try requiredID(arguments, "thread_id", from: "list_mail or search_mail")
        let maxMessages = try optionalInt(arguments, "max_messages", range: 1...20) ?? 10
        let includeHTML = try optionalBool(arguments, "include_html") ?? false
        let thread = try await request(account, context: "mcp.mail.thread") { try await $0.mailThread(conversationID: id, ignoringFolders: []) }
        let ownDomain = Self.domain(await ownAddress(account))
        var budget = Self.maxThreadCharacters
        var result = commonFields(coder, account)
        result["thread_id"] = .string(handle(thread.id))
        result["open_url"] = openURL(.thread(id: thread.id, accountID: linkAccountID(account)))
        result["subject"] = .string(thread.topic)
        result["total_messages"] = .int(Int64(thread.totalMessageCount))
        let shown = Array(thread.messages.prefix(maxMessages))
        let newestPeople = shown.first.map(Self.people(of:))
        result["messages"] = .array(shown.enumerated().map { index, message in
            let view = compact ? CompactMessage(topic: thread.topic, newestPeople: index == 0 ? nil : newestPeople) : nil
            return messageJSON(message, coder, ownDomain: ownDomain, characterLimit: Self.maxMessageCharacters, includeHTML: includeHTML, compact: view, budget: &budget)
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
        let includeHTML = try optionalBool(arguments, "include_html") ?? false
        let message = try await request(account, context: "mcp.mail.message") { try await $0.mailMessage(MailItemRef(id: id, changeKey: nil)) }
        let ownDomain = Self.domain(await ownAddress(account))
        var budget = Self.maxFullMessageCharacters
        var result = commonFields(coder, account)
        result["message"] = messageJSON(message, coder, ownDomain: ownDomain, characterLimit: Self.maxFullMessageCharacters, includeHTML: includeHTML, budget: &budget)
        result["open_url"] = openURL(.message(id: message.ref.id, accountID: linkAccountID(account)))
        if let conversation = message.conversationID { result["thread_id"] = .string(handle(conversation)) }
        return .success(result)
    }

    // MARK: - prepare_mail

    private func prepareMail(_ arguments: [String: JSONValue], _ coder: MCPDateCoder, client: String?) async throws -> MCPToolResult {
        guard canSend() else { return .failure(.settingOff(.prepareMail, Self.sendDisabledMessage)) }
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
        let subjectArgument = MCPMeetingTextPolicy.normalizedSpaces(arguments["subject"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // What goes out is what the panel can show: runs of blank lines (spaces or invisible
        // characters count as blank) collapse, so a harmless first line cannot push the rest of
        // the text out of sight.
        let body = Self.normalizedBody(arguments["body"]?.stringValue ?? "")
        guard body.count <= Self.maxOutgoingBodyCharacters else { throw ToolError("`body` is limited to \(Self.maxOutgoingBodyCharacters) characters") }
        guard subjectArgument.count <= 255 else { throw ToolError("`subject` is limited to 255 characters") }
        for (name, text) in [("subject", subjectArgument), ("body", body)] where MCPMeetingTextPolicy.containsBidiControls(text) {
            throw ToolError("`\(name)` contains bidirectional control characters (U+202A–U+202E, U+2066–U+2069), which make text display differently from what is sent. Remove them.")
        }
        for (name, text) in [("subject", subjectArgument), ("body", body)] where MCPMeetingTextPolicy.containsHiddenCharacters(text) {
            throw ToolError("`\(name)` contains invisible characters (zero-width spaces, Unicode tags, variation selectors, control characters), which the user cannot see in the confirmation. Remove them.")
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
        let outgoing = MailOutgoing(kind: kind, reference: original?.ref, to: to, cc: cc, subject: subjectArgument, body: RichText(plain: body))

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
            return .failure(.rateLimited, "OWA Widget allows at most \(Self.sendsPerHour) emails per hour from AI assistants. Nothing was sent; the user can write it in OWA Widget's compose window.")
        }
        guard !isConfirming else {
            return .failure(.busy, "Another email is waiting for the user's answer in OWA Widget. Wait for that call to finish.")
        }
        panelTimes = panelTimes.filter { now.timeIntervalSince($0) < 3600 }
        guard panelTimes.count < Self.panelsPerHour else {
            return .failure(.busy, "OWA Widget shows at most \(Self.panelsPerHour) email confirmations an hour. Nothing was sent; the user can write the email in OWA Widget's compose window.")
        }
        if let lastDecline, now.timeIntervalSince(lastDecline) < Self.pauseAfterDecline {
            return .failure(.userDeclined, "The user just declined an email. Nothing was sent; ask the user before trying again.")
        }
        if let block = MCPAccessGuard.blockError(calendarService.syncStatus) { return .failure(block) }
        isConfirming = true
        defer { isConfirming = false }

        // A draft first, read back: for a reply Exchange works the recipients out itself (the
        // original's Reply-To, everyone on a reply-all) and may add them to the ones asked for.
        // The panel shows the server's list, so what the user approves is what goes out.
        var draftOutgoing = outgoing
        draftOutgoing.send = false
        let draftRequest = draftOutgoing
        let prepared: MailPreparedSend
        do {
            guard let ref = try await request(account, context: "mcp.mail.draft", { try await $0.mailSend(draftRequest) }) else {
                return .failure(.exchangeError, "Exchange did not save the draft. Nothing was sent.")
            }
            do {
                let message = try await request(account, context: "mcp.mail.review") { try await $0.mailDraftForReview(ref) }
                prepared = try MailPreparedSend.make(draft: message, outgoing: outgoing)
            } catch {
                discardDraft(ref, account)
                throw error
            }
        } catch let error as ToolError {
            throw error
        } catch {
            return .failure(MCPToolError.code(for: error), "OWA Widget could not prepare the email: \(error.localizedDescription). Nothing was sent.")
        }

        let known = Set(([original?.from?.email] + (original?.to ?? []).map(\.email) + (original?.cc ?? []).map(\.email)).compactMap { $0?.lowercased() })
        let requested = Set((to + cc).map { $0.lowercased() })
        let recipient = { (address: MailAddress) -> MCPMailProposal.Recipient in
            guard let email = address.email else {
                // No address to check: shown by name, flagged as both.
                return MCPMailProposal.Recipient(email: address.displayName, isExternal: true, isNew: true)
            }
            let lower = email.lowercased()
            return MCPMailProposal.Recipient(
                email: email,
                isExternal: Self.isExternal(email, ownDomain: ownDomain) ?? false,
                // Put there by the server, or not among the original's people: either way the
                // assistant did not get it from the thread the user sees.
                isNew: !requested.contains(lower) || (kind != .new && !known.contains(lower))
            )
        }
        let proposal = MCPMailProposal(
            kind: kind,
            to: prepared.to.map(recipient),
            cc: (prepared.cc + prepared.bcc).map(recipient),
            subject: shownSubject,
            body: body,
            original: original.map { MCPMailProposal.Original(from: $0.from?.displayName ?? "", subject: $0.subject, received: $0.received) },
            // Everything the draft carries, inline pictures included: a forward sends them all.
            forwardedAttachments: prepared.attachments.map(\.name),
            client: client ?? "",
            externalCheckAvailable: ownDomain != nil,
            canOpenDraft: canHandOff()
        )

        panelTimes.append(now)
        let answer = await confirmer.confirm(proposal, timeout: confirmationTimeout)
        if answer != .confirmed { discardDraft(prepared.draft, account) }
        if answer == .rejected || answer == .timedOut { lastDecline = clock() }
        switch answer {
        case .confirmed:
            // Settings or the client's mail access may have changed while the panel was open.
            guard canSend() else {
                discardDraft(prepared.draft, account)
                return .failure(.settingOff(.prepareMail, Self.sendDisabledMessage))
            }
        case .rejected:
            return .failure(.userDeclined, "The user declined in OWA Widget. Nothing was sent; do not retry unless the user asks.")
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
            return .failure(.userDeclined, "The user declined in OWA Widget. Nothing was sent; do not retry unless the user asks.")
        case .timedOut:
            return .failure(.confirmationTimeout, "The user did not answer in OWA Widget within \(Int(confirmationTimeout)) seconds. Nothing was sent; ask the user whether to try again.")
        case .cancelled:
            return .failure(.cancelled, "The request was cancelled. Nothing was sent.")
        }

        // Past "Send" the request finishes even if the client cancels: a half-known outcome is
        // the worst one for an email.
        guard accessGuard.permitRequest() == nil, let provider = calendarService.mailProvider(accountID: account.id) else {
            discardDraft(prepared.draft, account)
            return .failure(.offline, "OWA Widget could not reach Exchange right now. Nothing was sent.")
        }
        let guardRef = accessGuard
        let draft = prepared.draft
        let sending = Task { @MainActor in
            await guardRef.acquireSlot()
            defer { guardRef.releaseSlot() }
            try await provider.mailSendDraft(draft)
        }
        do {
            try await sending.value
        } catch {
            accessGuard.report(error, context: "mcp.mail.send")
            MCPDebugLog.log("prepare_mail send failed: \(error.localizedDescription)")
            if case .sendUncertain = error as? MailError {
                sendTimes.append(now)
                return .failure(.unconfirmed, "The connection broke while Exchange was sending. The email may have gone out: check the Sent folder (list_mail folder=sent) and do not send it again before that.")
            }
            return .failure(.exchangeError, "Exchange did not send the email: \(error.localizedDescription). It stays in the Drafts folder.")
        }
        sendTimes.append(now)
        var result = commonFields(coder, account)
        result["sent"] = true
        result["kind"] = .string(arguments["kind"]?.stringValue ?? "")
        result["to"] = .array(prepared.to.map { JSONValue.string($0.email ?? $0.displayName) })
        result["cc"] = .array((prepared.cc + prepared.bcc).map { JSONValue.string($0.email ?? $0.displayName) })
        result["subject"] = .string(shownSubject)
        result["note"] = "Sent by Exchange; a copy is in the Sent folder."
        recentSends[key] = (now, result)
        return .success(result)
    }

    // MARK: - set_mail_read

    /// Marks conversations read or unread. The threads are read first, ten per request (their
    /// messages as the server holds them now, Deleted Items left out as in the mail window: one
    /// gone comes back in `failed`), then marked through `MailService`, so the app's counts
    /// follow. Exchange marks the other messages when one fails, and `failed` names only the
    /// conversations that were not marked in full.
    private func setMailRead(_ arguments: [String: JSONValue]) async throws -> MCPToolResult {
        guard canOrganize() else { return .failure(.settingOff(.markMail, Self.organizeDisabledMessage)) }
        guard let isRead = arguments["read"]?.boolValue else {
            throw ToolError("`read` is required: true marks the conversations read, false unread")
        }
        guard let items = arguments["thread_ids"]?.arrayValue else {
            throw ToolError("`thread_ids` must be an array of thread_id values from list_mail, search_mail or get_mail_thread")
        }
        guard !items.isEmpty else { throw ToolError("`thread_ids` is empty") }
        guard items.count <= Self.maxThreadsPerMark else {
            throw ToolError("At most \(Self.maxThreadsPerMark) conversations per call, got \(items.count). Nothing was changed: split them into several calls.")
        }
        let raw = try items.map { item in
            guard let text = item.stringValue?.trimmingCharacters(in: .whitespaces), !text.isEmpty else {
                throw ToolError("`thread_ids` must contain thread_id strings")
            }
            return text
        }
        let account = try mailAccount(arguments)
        guard let marker = readMarker else {
            return .failure(.notReady, "OWA Widget cannot mark mail right now (it is still starting). Nothing was changed; try again in a minute.")
        }
        if let block = MCPAccessGuard.blockError(calendarService.syncStatus) { return .failure(block) }
        // A conversation also holds its copies in Deleted Items: marking the newest one "unread"
        // there would leave the inbox conversation read.
        let ignored = try await folders(account, load: true)?
            .filter { $0.distinguished == .deleteditems }.map(\.id) ?? []

        var failed: [JSONValue] = []
        func fail(_ threadID: String, _ reason: MCPToolError) {
            failed.append(Self.failure(threadID, reason))
        }
        func reason(_ error: any Error) -> MCPToolError { Self.reason(error) }

        var wanted: [(threadID: String, id: String)] = []
        var seen: Set<String> = []
        for threadID in raw {
            guard let id = resolve(threadID) else {
                fail(threadID, MCPToolError(.notFound, "unknown thread_id: ids are remembered only while OWA Widget runs — list or search again"))
                continue
            }
            if seen.insert(id).inserted { wanted.append((threadID, id)) }
        }

        var threads: [(threadID: String, thread: MailThread)] = []
        // The budget, a blocked sync or the connection: the next requests would fare no better,
        // and each one sends the password again.
        var stopReason: MCPToolError?
        for batch in wanted.chunked(Self.threadsPerMarkRead) {
            if let stopReason {
                for entry in batch { fail(entry.threadID, stopReason) }
                continue
            }
            let ids = batch.map(\.id)
            do {
                let results = try await request(account, context: "mcp.mail.setRead") {
                    try await $0.mailThreads(conversationIDs: ids, ignoringFolders: ignored)
                }
                for (entry, result) in zip(batch, results) {
                    switch result {
                    case .success(let thread) where !thread.messages.isEmpty: threads.append((entry.threadID, thread))
                    case .success: fail(entry.threadID, Self.goneReason)
                    case .failure(let error): fail(entry.threadID, reason(error))
                    }
                }
            } catch {
                stopReason = reason(error)
                for entry in batch { fail(entry.threadID, reason(error)) }
            }
        }

        var updated = 0
        if let stopReason {
            for entry in threads { fail(entry.threadID, stopReason) }
        } else if !threads.isEmpty {
            let own = isRead ? nil : await ownAddress(account)
            let outcome = await marker.setRead(threads: threads.map(\.thread), isRead, accountID: account.id, ownAddress: own) { operation in
                try await request(account, context: "mcp.mail.setRead", operation)
            }
            for (entry, error) in zip(threads, outcome) {
                if let error { fail(entry.threadID, reason(error)) } else { updated += 1 }
            }
        }
        MCPDebugLog.log("set_mail_read read=\(isRead) asked=\(raw.count) updated=\(updated) failed=\(failed.count)")
        return .success(["updated": .int(Int64(updated)), "failed": .array(failed)])
    }

    private static let goneReason = MCPToolError(.notFound, "not found: the conversation was deleted or moved — list or search again")

    // MARK: - Moving and flagging (`move_mail`, `set_mail_flag`)

    /// What a `move_mail` answer can undo: the messages it moved, by their new ids, and the
    /// folder each one came from. In memory, so an undo works until OWA Widget restarts.
    private struct MoveUndo {
        struct Item {
            let threadID: String
            let conversationID: String
            let ref: MailItemRef
            let folderID: String
            let backTo: String
            let isRead: Bool
        }
        let accountID: UUID
        let items: [Item]
        let date: Date
        /// The answer of the undo once it ran: a repeated undo returns it again, moving nothing.
        var answer: [String: JSONValue]?
    }

    private func threadIDs(_ arguments: [String: JSONValue]) throws -> [String] {
        guard let items = arguments["thread_ids"]?.arrayValue else {
            throw ToolError("`thread_ids` must be an array of thread_id values from list_mail, search_mail or get_mail_thread")
        }
        guard !items.isEmpty else { throw ToolError("`thread_ids` is empty") }
        guard items.count <= Self.maxThreadsPerMark else {
            throw ToolError("At most \(Self.maxThreadsPerMark) conversations per call, got \(items.count). Nothing was changed: split them into several calls.")
        }
        return try items.map { item in
            guard let text = item.stringValue?.trimmingCharacters(in: .whitespaces), !text.isEmpty else {
                throw ToolError("`thread_ids` must contain thread_id strings")
            }
            return text
        }
    }

    private static func reason(_ error: any Error) -> MCPToolError {
        if case MailError.notFound? = error as? MailError { return goneReason }
        if let error = error as? MCPToolError { return error }
        return MCPToolError(MCPToolError.code(for: error), error.localizedDescription)
    }

    /// One `failed` entry: the reason the model reads and its code.
    private static func failure(_ threadID: String, _ reason: MCPToolError) -> JSONValue {
        ["thread_id": .string(threadID), "reason": .string(reason.message), "code": .string(reason.code.rawValue)]
    }

    /// Resolves `thread_ids`, one entry per conversation; unknown ids go to `failed`.
    private func wantedThreads(_ raw: [String], failed: inout [JSONValue]) -> [(threadID: String, id: String)] {
        var wanted: [(threadID: String, id: String)] = []
        var seen: Set<String> = []
        for threadID in raw {
            guard let id = resolve(threadID) else {
                failed.append(Self.failure(threadID, MCPToolError(.notFound, "unknown thread_id: ids are remembered only while OWA Widget runs — list or search again")))
                continue
            }
            if seen.insert(id).inserted { wanted.append((threadID, id)) }
        }
        return wanted
    }

    /// Reads conversations ten per request. A request that fails as a whole (budget, blocked
    /// sync, connection) stops the rest: the next would fare no better, and each one sends the
    /// password again. Returns the threads read and that reason, if any.
    private func readThreads(
        _ wanted: [(threadID: String, id: String)],
        _ account: CalendarAccount,
        ignoring: [String],
        context: String,
        failed: inout [JSONValue]
    ) async -> (threads: [(threadID: String, thread: MailThread)], stop: MCPToolError?) {
        var threads: [(threadID: String, thread: MailThread)] = []
        var stop: MCPToolError?
        for batch in wanted.chunked(Self.threadsPerMarkRead) {
            if let stop {
                for entry in batch { failed.append(Self.failure(entry.threadID, stop)) }
                continue
            }
            let ids = batch.map(\.id)
            do {
                let results = try await request(account, context: context) {
                    try await $0.mailThreads(conversationIDs: ids, ignoringFolders: ignoring)
                }
                for (entry, result) in zip(batch, results) {
                    switch result {
                    case .success(let thread): threads.append((entry.threadID, thread))
                    case .failure(let error): failed.append(Self.failure(entry.threadID, Self.reason(error)))
                    }
                }
            } catch {
                stop = Self.reason(error)
                for entry in batch { failed.append(Self.failure(entry.threadID, Self.reason(error))) }
            }
        }
        return (threads, stop)
    }

    /// A folder of the tree by system name, folder_id or name.
    private func pickFolder(_ raw: String, in list: [MailFolder], argument: String) throws -> MailFolder {
        let text = raw.trimmingCharacters(in: .whitespaces)
        if let system = Self.systemFolderNames[text.lowercased()] {
            guard let folder = list.first(where: { $0.distinguished == system }) else {
                if system == .archive {
                    throw ToolError(.noArchiveFolder, "This mailbox has no Archive folder (Exchange creates it the first time Archive is used in Outlook or OWA). Nothing was moved: pick another folder from list_mail_folders, or ask the user to archive one message in OWA once.")
                }
                throw ToolError(.notFound, "This mailbox has no `\(text)` folder. Nothing was moved.")
            }
            return folder
        }
        if let id = resolve(text), let folder = list.first(where: { $0.id == id }) { return folder }
        let named = list.filter { $0.displayName.caseInsensitiveCompare(text) == .orderedSame }
        if named.count == 1 { return named[0] }
        if named.count > 1 {
            throw ToolError("Several folders are named `\(text)`: pass `\(argument)` as a folder_id from list_mail_folders. Nothing was moved.")
        }
        throw ToolError(.notFound, "Unknown folder `\(text)` in `\(argument)`. Use inbox, archive, a folder name or a folder_id from list_mail_folders. Nothing was moved.")
    }

    /// The folder and the ones above it, nearest first.
    private static func lineage(_ folder: MailFolder, in list: [MailFolder]) -> [MailFolder] {
        var chain = [folder]
        var parent = folder.parentID
        while let id = parent, chain.count < 32, let next = list.first(where: { $0.id == id }) {
            chain.append(next)
            parent = next.parentID
        }
        return chain
    }

    /// Why nothing may go into `folder`: Deleted Items (deleting is not a move) and the rest of
    /// Exchange's own folders other than Inbox and Archive, with every folder under them.
    private static func destinationRefusal(_ folder: MailFolder, in list: [MailFolder]) -> String? {
        for node in lineage(folder, in: list) {
            if let system = node.distinguished, forbiddenDestinations.contains(system) {
                return "Nothing is moved into `\(folder.displayName)`: move_mail does not delete, draft, send or mark as junk."
            }
            if node.distinguished == nil, node.distinguishedID != nil, node.id == folder.id {
                return "`\(folder.displayName)` is one of Exchange's own folders; move_mail moves only to inbox, archive and the user's folders."
            }
        }
        return nil
    }

    private func folderJSON(_ folder: MailFolder) -> JSONValue {
        ["folder_id": .string(handle(folder.id)), "name": .string(folder.displayName), "system": .optional(folder.distinguishedID)]
    }

    private func rememberUndo(_ undo: MoveUndo) -> String {
        let now = clock()
        for key in moveUndoOrder where now.timeIntervalSince(moveUndos[key]?.date ?? now) > Self.moveUndoLifetime {
            moveUndos[key] = nil
        }
        moveUndoOrder.removeAll { moveUndos[$0] == nil }
        let id = "u" + MCPShortHash.hex(undo.items.map(\.ref.id).joined(separator: ",") + "\(now.timeIntervalSince1970)", bytes: 5)
        moveUndos[id] = undo
        moveUndoOrder.append(id)
        if moveUndoOrder.count > Self.moveUndoLimit { moveUndos[moveUndoOrder.removeFirst()] = nil }
        return id
    }

    private struct PlannedMove {
        let threadID: String
        let conversationID: String
        let message: MailMessage
        let backTo: String
    }

    /// Moves messages in requests of `bulkPageSize`. Returns the new ref (or the error) of each
    /// message in order, and why it stopped when a request failed as a whole.
    private func performMoves(_ refs: [MailItemRef], to folderID: String, _ account: CalendarAccount) async -> (results: [Result<MailItemRef, any Error>], stop: MCPToolError?) {
        var results: [Result<MailItemRef, any Error>] = []
        var stop: MCPToolError?
        for chunk in refs.chunked(MailService.bulkPageSize) {
            if let stop {
                results += chunk.map { _ in .failure(stop) }
                continue
            }
            do {
                let moved = try await request(account, context: "mcp.mail.move") { try await $0.mailMoveEach(chunk, to: .id(folderID)) }
                results += moved.map { $0.mapError { $0 as any Error } }
            } catch {
                stop = Self.reason(error)
                results += chunk.map { _ in .failure(error) }
            }
        }
        return (results, stop)
    }

    /// Moves conversations: every message of each one that sits in `from_folder` (Inbox by
    /// default) goes to `folder`, with `MoveItem` — the request OWA's own Archive button sends.
    /// The answer names the new ids and an `undo_id` that moves them back. Nothing goes to
    /// Deleted Items or Exchange's other own folders.
    private func moveMail(_ arguments: [String: JSONValue]) async throws -> MCPToolResult {
        guard canArrange() else { return .failure(.settingOff(.arrangeMail, Self.arrangeDisabledMessage)) }
        if let undoID = arguments["undo_id"], undoID != .null {
            guard arguments["thread_ids"] == nil, arguments["folder"] == nil, arguments["from_folder"] == nil else {
                throw ToolError("Pass either `undo_id` alone or `thread_ids` with `folder`. Nothing was moved.")
            }
            guard let text = undoID.stringValue?.trimmingCharacters(in: .whitespaces), !text.isEmpty else {
                throw ToolError("`undo_id` must be the `undo_id` string of an earlier move_mail answer")
            }
            return try await undoMove(text, arguments)
        }
        let raw = try threadIDs(arguments)
        guard let folderText = arguments["folder"]?.stringValue, !folderText.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ToolError("`folder` is required: archive, inbox, a folder name or a folder_id from list_mail_folders")
        }
        let account = try mailAccount(arguments)
        if let block = MCPAccessGuard.blockError(calendarService.syncStatus) { return .failure(block) }
        let list = try await folders(account, load: true) ?? []
        let target = try pickFolder(folderText, in: list, argument: "folder")
        if let refusal = Self.destinationRefusal(target, in: list) { throw ToolError(.forbiddenFolder, refusal + " Nothing was moved.") }
        let source = try pickFolder(arguments["from_folder"]?.stringValue ?? "inbox", in: list, argument: "from_folder")
        if Self.lineage(source, in: list).contains(where: { $0.distinguished == .deleteditems }) {
            throw ToolError(.forbiddenFolder, "`from_folder` cannot be Deleted Items: move_mail does not restore deleted mail. Nothing was moved.")
        }
        guard source.id != target.id else {
            throw ToolError("`folder` and `from_folder` are the same folder (\(target.displayName)). Nothing was moved.")
        }
        // Deleted Items as in the mail window; the destination too, so a later round of a long
        // conversation reads the messages that did not fit into the first one.
        let ignored = list.filter { $0.distinguished == .deleteditems }.map(\.id) + [target.id]

        var failed: [JSONValue] = []
        var pending = wantedThreads(raw, failed: &failed)
        var movedByThread: [String: [MoveUndo.Item]] = [:]
        var notMoved: [String: Int] = [:]
        var touched: [String] = []
        var observed: [MCPMailMove] = []
        var stop: MCPToolError?
        for round in 0..<Self.moveRounds where !pending.isEmpty && stop == nil {
            let read = await readThreads(pending, account, ignoring: ignored, context: "mcp.mail.move", failed: &failed)
            if let reason = read.stop {
                // Read before the stop, but not moved: they still get an answer.
                for (threadID, _) in read.threads { failed.append(Self.failure(threadID, reason)) }
                stop = reason
                break
            }
            var plan: [PlannedMove] = []
            var again: [(threadID: String, id: String)] = []
            for (threadID, thread) in read.threads {
                let inSource = thread.messages.filter { $0.parentFolderID == source.id }
                if inSource.isEmpty {
                    if round == 0 {
                        failed.append(Self.failure(threadID, MCPToolError(.notFound, "nothing to move: no message of this conversation is in \(source.displayName) (moved already? pass `from_folder`)")))
                    }
                    continue
                }
                if !touched.contains(threadID) { touched.append(threadID) }
                plan += inSource.map { PlannedMove(threadID: threadID, conversationID: thread.id, message: $0, backTo: source.id) }
                if thread.messages.count < thread.totalMessageCount { again.append((threadID, thread.id)) }
            }
            guard stop == nil, !plan.isEmpty else { break }
            let outcome = await performMoves(plan.map(\.message.ref), to: target.id, account)
            stop = outcome.stop
            var failedThreads: Set<String> = []
            for (move, result) in zip(plan, outcome.results) {
                switch result {
                case .success(let ref):
                    movedByThread[move.threadID, default: []].append(MoveUndo.Item(
                        threadID: move.threadID, conversationID: move.conversationID, ref: ref,
                        folderID: target.id, backTo: move.backTo, isRead: move.message.isRead
                    ))
                    observed.append(MCPMailMove(conversationID: move.conversationID, oldID: move.message.ref.id, fromFolderID: source.id, toFolderID: target.id, isRead: move.message.isRead))
                case .failure(let error):
                    notMoved[move.threadID, default: 0] += 1
                    if failedThreads.insert(move.threadID).inserted {
                        failed.append(Self.failure(move.threadID, Self.reason(error)))
                    }
                }
            }
            pending = again.filter { !failedThreads.contains($0.threadID) }
        }
        arrangeObserver?.mailMovedByAssistant(observed, accountID: account.id)

        let items = touched.flatMap { movedByThread[$0] ?? [] }
        var moved: [JSONValue] = []
        for threadID in touched {
            guard let entries = movedByThread[threadID], !entries.isEmpty else { continue }
            var entry: [String: JSONValue] = [
                "thread_id": .string(threadID),
                "messages": .int(Int64(entries.count)),
                "message_ids": .array(entries.map { .string(handle($0.ref.id)) }),
            ]
            if let left = notMoved[threadID] { entry["not_moved"] = .int(Int64(left)) }
            moved.append(.object(entry))
        }
        var result: [String: JSONValue] = [
            "moved": .array(moved),
            "failed": .array(failed),
            "from_folder": folderJSON(source),
            "to_folder": folderJSON(target),
            "undo_id": .null,
        ]
        if !items.isEmpty {
            result["undo_id"] = .string(rememberUndo(MoveUndo(accountID: account.id, items: items, date: clock())))
        }
        MCPDebugLog.log("move_mail asked=\(raw.count) moved=\(moved.count) messages=\(items.count) failed=\(failed.count)")
        return .success(result)
    }

    /// Moves what an earlier `move_mail` moved back where each message came from. Its answer has
    /// an `undo_id` of its own (to move them again); repeating the undo moves nothing.
    private func undoMove(_ undoID: String, _ arguments: [String: JSONValue]) async throws -> MCPToolResult {
        guard var undo = moveUndos[undoID], clock().timeIntervalSince(undo.date) <= Self.moveUndoLifetime else {
            throw ToolError(.notFound, "Unknown `undo_id` \(undoID): an undo is remembered for 24 hours and only while OWA Widget runs. Nothing was moved; move the conversations with `thread_ids` and `folder` instead.")
        }
        if var answer = undo.answer {
            answer["repeated"] = true
            return .success(answer)
        }
        guard let account = calendarService.mailAccounts.first(where: { $0.id == undo.accountID }) else {
            throw ToolError(.notFound, "The account of this move is no longer connected. Nothing was moved.")
        }
        if let raw = arguments["account_id"]?.stringValue, UUID(uuidString: raw) != account.id {
            throw ToolError("This `undo_id` belongs to another account. Nothing was moved.")
        }
        if let block = MCPAccessGuard.blockError(calendarService.syncStatus) { return .failure(block) }
        let list = try await folders(account, load: true) ?? []

        var failed: [JSONValue] = []
        var redo: [MoveUndo.Item] = []
        var observed: [MCPMailMove] = []
        var movedCount: [String: Int] = [:]
        var messageIDs: [String: [String]] = [:]
        var order: [String] = []
        var failedThreads: Set<String> = []
        var stop: MCPToolError?
        let groups = Dictionary(grouping: undo.items, by: \.backTo)
        for (folderID, items) in groups.sorted(by: { $0.key < $1.key }) {
            for item in items where !order.contains(item.threadID) { order.append(item.threadID) }
            func fail(_ reason: MCPToolError) {
                for item in items where failedThreads.insert(item.threadID).inserted { failed.append(Self.failure(item.threadID, reason)) }
            }
            if let stop { fail(stop); continue }
            guard list.contains(where: { $0.id == folderID }) else {
                fail(MCPToolError(.notFound, "the folder these messages came from no longer exists"))
                continue
            }
            let outcome = await performMoves(items.map(\.ref), to: folderID, account)
            stop = outcome.stop
            for (item, result) in zip(items, outcome.results) {
                switch result {
                case .success(let ref):
                    redo.append(MoveUndo.Item(threadID: item.threadID, conversationID: item.conversationID, ref: ref, folderID: folderID, backTo: item.folderID, isRead: item.isRead))
                    observed.append(MCPMailMove(conversationID: item.conversationID, oldID: item.ref.id, fromFolderID: item.folderID, toFolderID: folderID, isRead: item.isRead))
                    movedCount[item.threadID, default: 0] += 1
                    messageIDs[item.threadID, default: []].append(handle(ref.id))
                case .failure(let error):
                    if failedThreads.insert(item.threadID).inserted { failed.append(Self.failure(item.threadID, Self.reason(error))) }
                }
            }
        }
        arrangeObserver?.mailMovedByAssistant(observed, accountID: account.id)
        let moved: [JSONValue] = order.compactMap { threadID in
            guard let count = movedCount[threadID] else { return nil }
            return ["thread_id": .string(threadID), "messages": .int(Int64(count)), "message_ids": .array((messageIDs[threadID] ?? []).map(JSONValue.string))]
        }
        var answer: [String: JSONValue] = ["moved": .array(moved), "failed": .array(failed), "undone": .string(undoID), "undo_id": .null]
        if !redo.isEmpty {
            answer["undo_id"] = .string(rememberUndo(MoveUndo(accountID: account.id, items: redo, date: clock())))
        }
        // Retried only while nothing was moved: once some messages went back, a repeat would
        // find them gone and report every one as failed.
        if !redo.isEmpty || failed.isEmpty {
            undo.answer = answer
            moveUndos[undoID] = undo
        }
        MCPDebugLog.log("move_mail undo messages=\(redo.count) failed=\(failed.count)")
        return .success(answer)
    }

    /// Flags or unflags conversations: `true` flags the newest message the user received (as a
    /// flag on a conversation in OWA does) unless one is flagged already; `false` clears every
    /// flagged message. Repeating a call changes nothing (`unchanged`).
    private func setMailFlag(_ arguments: [String: JSONValue]) async throws -> MCPToolResult {
        guard canArrange() else { return .failure(.settingOff(.arrangeMail, Self.arrangeDisabledMessage)) }
        guard let flagged = arguments["flagged"]?.boolValue else {
            throw ToolError("`flagged` is required: true flags the conversations, false clears their flags")
        }
        let raw = try threadIDs(arguments)
        let account = try mailAccount(arguments)
        if let block = MCPAccessGuard.blockError(calendarService.syncStatus) { return .failure(block) }
        let ignored = try await folders(account, load: true)?
            .filter { $0.distinguished == .deleteditems }.map(\.id) ?? []

        var failed: [JSONValue] = []
        let wanted = wantedThreads(raw, failed: &failed)
        let read = await readThreads(wanted, account, ignoring: ignored, context: "mcp.mail.flag", failed: &failed)
        if let stop = read.stop {
            for entry in read.threads { failed.append(Self.failure(entry.threadID, stop)) }
            return .success(["updated": 0, "unchanged": .array([]), "failed": .array(failed)])
        }
        let own = flagged ? await ownAddress(account) : nil
        var unchanged: [JSONValue] = []
        var plan: [(threadID: String, conversationID: String, target: MailItemTarget)] = []
        for (threadID, thread) in read.threads {
            guard !thread.messages.isEmpty else {
                failed.append(Self.failure(threadID, Self.goneReason))
                continue
            }
            let messages: [MailMessage]
            if flagged {
                if thread.messages.contains(where: \.isFlagged) {
                    messages = []
                } else {
                    let ownEmail = own?.lowercased()
                    let received = thread.messages.filter { !$0.isDraft && (ownEmail == nil || $0.from?.email?.lowercased() != ownEmail) }
                    messages = Array((received.first ?? thread.messages.first).map { [$0] } ?? [])
                }
            } else {
                messages = thread.messages.filter(\.isFlagged)
            }
            if messages.isEmpty {
                unchanged.append(.string(threadID))
                continue
            }
            plan += messages.map { (threadID, thread.id, MailItemTarget($0.ref, kind: $0.kind)) }
        }

        var failedThreads: Set<String> = []
        var done: [String] = []
        var doneMessages: [String] = []
        var doneConversations: [String] = []
        var stop: MCPToolError?
        let status: MailFlagStatus = flagged ? .flagged : .notFlagged
        for chunk in plan.chunked(MailService.bulkPageSize) {
            if let stop {
                for entry in chunk where failedThreads.insert(entry.threadID).inserted { failed.append(Self.failure(entry.threadID, stop)) }
                continue
            }
            do {
                let targets = chunk.map(\.target)
                let results = try await request(account, context: "mcp.mail.flag") { try await $0.mailUpdateEach(targets, .flag(status)) }
                for (entry, result) in zip(chunk, results) {
                    switch result {
                    case .success:
                        doneMessages.append(entry.target.ref.id)
                        doneConversations.append(entry.conversationID)
                    case .failure(let error):
                        if failedThreads.insert(entry.threadID).inserted { failed.append(Self.failure(entry.threadID, Self.reason(error))) }
                    }
                }
            } catch {
                stop = Self.reason(error)
                for entry in chunk where failedThreads.insert(entry.threadID).inserted { failed.append(Self.failure(entry.threadID, Self.reason(error))) }
            }
        }
        for entry in plan where !failedThreads.contains(entry.threadID) && !done.contains(entry.threadID) { done.append(entry.threadID) }
        arrangeObserver?.mailFlaggedByAssistant(conversationIDs: doneConversations, messageIDs: doneMessages, flagged: flagged, accountID: account.id)
        MCPDebugLog.log("set_mail_flag flagged=\(flagged) asked=\(raw.count) updated=\(done.count) unchanged=\(unchanged.count) failed=\(failed.count)")
        return .success(["updated": .int(Int64(done.count)), "unchanged": .array(unchanged), "failed": .array(failed)])
    }
}
