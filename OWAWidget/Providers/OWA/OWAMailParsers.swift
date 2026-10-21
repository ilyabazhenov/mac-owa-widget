import Foundation

/// Turns OWA mail responses into the app's models.
///
/// Tolerant by design, like `OWAFindPeopleParser`: an unknown field is ignored, an element missing
/// what identifies it (`ConversationId`, `ItemId`) is dropped on its own, and only a response that
/// is not JSON at all or reports an error fails as a whole.
enum OWAMailParsers {
    // MARK: - Errors

    /// The first error a response reports, from either shape OWA uses: a `ResponseCode` on the
    /// body itself (`FindConversation`, `ExecuteSearch`) or on each of `ResponseMessages.Items`.
    static func errorCode(in json: Any) -> String? {
        guard let body = (json as? [String: Any])?["Body"] as? [String: Any] else { return nil }
        if let code = body["ResponseCode"] as? String, code != "NoError" { return code }
        let items = (body["ResponseMessages"] as? [String: Any])?["Items"] as? [[String: Any]] ?? []
        for item in items {
            if let code = item["ResponseCode"] as? String, code != "NoError" { return code }
        }
        return nil
    }

    /// `MessageText` next to the first error code, from the same two shapes as `errorCode(in:)`.
    static func errorText(in json: Any) -> String? {
        guard let body = (json as? [String: Any])?["Body"] as? [String: Any] else { return nil }
        if let code = body["ResponseCode"] as? String, code != "NoError" { return body["MessageText"] as? String }
        let items = (body["ResponseMessages"] as? [String: Any])?["Items"] as? [[String: Any]] ?? []
        return items.first { ($0["ResponseCode"] as? String).map { $0 != "NoError" } ?? false }?["MessageText"] as? String
    }

    static func json(_ data: Data) throws -> Any {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { throw OWAError.invalidResponse }
        if let code = errorCode(in: json) {
            let isIDError = code == "ErrorItemNotFound" || code == "ErrorInvalidIdMalformed" || code == "ErrorInvalidIdNotAnItemAttachmentId"
            // The server's wording only for a wrong id: it names id types ("ID type 9; actual
            // type 12"), which tells a stale id from a request bound to the wrong type. Other
            // errors may quote addresses or file names in it, and the code alone goes.
            let text = isIDError ? errorText(in: json).map { " text=" + String($0.prefix(200)) } ?? "" : ""
            DiagnosticLog.event("Mail server error code=\(code)\(text)")
            if isIDError {
                throw MailError.notFound
            }
            throw MailError.serverError(code)
        }
        return json
    }

    private static func body(_ json: Any) -> [String: Any] {
        (json as? [String: Any])?["Body"] as? [String: Any] ?? [:]
    }

    private static func responseItems(_ json: Any) -> [[String: Any]] {
        (body(json)["ResponseMessages"] as? [String: Any])?["Items"] as? [[String: Any]] ?? []
    }

    // MARK: - Values

    // ISO8601DateFormatter is thread-safe once configured.
    nonisolated(unsafe) private static let isoWithOffset: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    nonisolated(unsafe) private static let isoWithFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// OWA answers in the time zone of the request, with its offset. A value without an offset
    /// (attachment times) is read in `fallbackZone`.
    static func date(_ value: Any?, fallbackZone: TimeZone = AppTimeZone.zone) -> Date? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        if let date = isoWithOffset.date(from: text) ?? isoWithFraction.date(from: text) { return date }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = fallbackZone
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss.SSS"] {
            f.dateFormat = format
            if let date = f.date(from: text) { return date }
        }
        return nil
    }

    private static func string(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : text
    }

    private static func int(_ value: Any?) -> Int? {
        if let n = value as? Int { return n }
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String { return Int(s) }
        return nil
    }

    private static func bool(_ value: Any?) -> Bool {
        if let b = value as? Bool { return b }
        if let n = value as? NSNumber { return n.boolValue }
        return false
    }

    private static func idValue(_ value: Any?) -> String? {
        string((value as? [String: Any])?["Id"])
    }

    static func itemRef(_ value: Any?) -> MailItemRef? {
        guard let dict = value as? [String: Any], let id = string(dict["Id"]) else { return nil }
        return MailItemRef(id: id, changeKey: string(dict["ChangeKey"]))
    }

    /// A mailbox from `From`, `Sender` or a recipient list. An Exchange-internal address (`EX`
    /// routing, a legacy DN) is not an address anyone can write to: kept as name only.
    static func address(_ value: Any?) -> MailAddress? {
        guard var dict = value as? [String: Any] else { return nil }
        if let mailbox = dict["Mailbox"] as? [String: Any] { dict = mailbox }
        let name = (dict["Name"] as? String) ?? ""
        var email = string(dict["EmailAddress"])
        if let routing = dict["RoutingType"] as? String, routing.uppercased() == "EX" { email = nil }
        if let current = email, current.hasPrefix("/") || !current.contains("@") { email = nil }
        if name.isEmpty && email == nil { return nil }
        return MailAddress(name: name, email: email)
    }

    /// `Sender` when it is someone other than `From`, nil otherwise.
    static func onBehalfSender(from: MailAddress?, sender: MailAddress?) -> MailAddress? {
        guard let from, let sender else { return nil }
        if let a = from.email?.lowercased(), let b = sender.email?.lowercased() {
            return a == b ? nil : sender
        }
        let fromName = from.displayName.lowercased(), senderName = sender.displayName.lowercased()
        return fromName.isEmpty || senderName.isEmpty || fromName == senderName ? nil : sender
    }

    static func addresses(_ value: Any?) -> [MailAddress] {
        (value as? [Any] ?? []).compactMap(address)
    }

    private static func categories(_ value: Any?) -> [String] {
        (value as? [Any] ?? []).compactMap { $0 as? String }.filter { !$0.isEmpty }
    }

    private static func isFlagged(_ value: Any?) -> Bool {
        if let status = value as? String { return status == "Flagged" }
        if let dict = value as? [String: Any], let status = dict["FlagStatus"] as? String { return status == "Flagged" }
        return false
    }

    private static func previewText(_ value: Any?) -> String {
        guard let text = value as? String else { return "" }
        return text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Folders

    /// Folders from any response that carries them: `GetFolder`, or the `findFolders` part of
    /// `sessiondata.ashx`, whose exact nesting differs between builds — so this walks the tree
    /// for objects that look like folders.
    static func folders(in json: Any) -> [MailFolder] {
        var result: [MailFolder] = []
        var seen = Set<String>()
        func walk(_ value: Any, depth: Int) {
            guard depth < 12 else { return }
            if let dict = value as? [String: Any] {
                if let folder = folder(from: dict), !seen.contains(folder.id) {
                    seen.insert(folder.id)
                    result.append(folder)
                }
                for (_, child) in dict { walk(child, depth: depth + 1) }
            } else if let array = value as? [Any] {
                for child in array { walk(child, depth: depth + 1) }
            }
        }
        walk(json, depth: 0)
        return result
    }

    private static func folder(from dict: [String: Any]) -> MailFolder? {
        guard let id = idValue(dict["FolderId"]) else { return nil }
        let type = dict["__type"] as? String ?? "Folder"
        // Calendars, contacts, tasks and search folders are not mail.
        guard type.hasPrefix("Folder") else { return nil }
        if let folderClass = dict["FolderClass"] as? String, !folderClass.isEmpty {
            // RSS feeds are `IPF.Note.OutlookHomepage`: mail-like, but not mail.
            guard folderClass == "IPF.Note" || (folderClass.hasPrefix("IPF.Note.") && !folderClass.contains("OutlookHomepage")) else {
                return nil
            }
        }
        let distinguished = string(dict["DistinguishedFolderId"])
        let name = string(dict["DisplayName"]) ?? distinguished ?? ""
        return MailFolder(
            id: id,
            distinguishedID: distinguished,
            displayName: name,
            parentID: idValue(dict["ParentFolderId"]),
            unreadCount: int(dict["UnreadCount"]) ?? 0,
            totalCount: int(dict["TotalCount"]) ?? 0,
            childFolderCount: int(dict["ChildFolderCount"]) ?? 0
        )
    }

    // MARK: - Conversations

    static func conversation(from dict: [String: Any]) -> MailConversationSummary? {
        guard let id = idValue(dict["ConversationId"]) else { return nil }
        let refs = (dict["ItemIds"] as? [Any] ?? []).compactMap(itemRef)
        let preview = MailExternalBanner.strip(previewText(dict["Preview"]))
        var summary = MailConversationSummary(
            id: id,
            topic: (dict["ConversationTopic"] as? String) ?? "",
            senders: (dict["UniqueSenders"] as? [Any] ?? []).compactMap { $0 as? String },
            recipients: (dict["UniqueRecipients"] as? [Any] ?? []).compactMap { $0 as? String },
            lastDelivery: date(dict["LastDeliveryTime"]) ?? date(dict["LastDeliveryOrRenewTime"]),
            messageCount: int(dict["MessageCount"]) ?? max(1, refs.count),
            globalMessageCount: int(dict["GlobalMessageCount"]) ?? int(dict["MessageCount"]) ?? max(1, refs.count),
            unreadCount: int(dict["UnreadCount"]) ?? 0,
            hasAttachments: bool(dict["HasAttachments"]),
            importance: MailImportance(owaValue: dict["Importance"] as? String),
            preview: preview.text,
            itemRefs: refs,
            categories: categories(dict["Categories"]),
            isFlagged: isFlagged(dict["FlagStatus"]),
            isProtected: bool(dict["HasIrm"]),
            instanceKey: string(dict["InstanceKey"]),
            parentFolderID: idValue(dict["ParentFolderId"])
        )
        summary.senderEmail = string(dict["SenderSMTPAddress"]) ?? address(dict["From"])?.email
        summary.itemClasses = (dict["ItemClasses"] as? [Any] ?? []).compactMap { $0 as? String }
        summary.hasExternalBanner = preview.found
        return summary
    }

    static func conversationPage(_ data: Data, requested: Int) throws -> MailConversationPage {
        let body = body(try json(data))
        let conversations = (body["Conversations"] as? [[String: Any]] ?? []).compactMap(conversation(from:))
        let total = int(body["TotalConversationsInView"])
        let offset = int(body["IndexedOffset"])
        let hasMore: Bool
        if let total, let offset {
            hasMore = offset < total
        } else {
            hasMore = conversations.count >= requested
        }
        let next = hasMore ? conversations.last?.instanceKey.map { MailListCursor.after(instanceKey: $0) } : nil
        return MailConversationPage(conversations: conversations, totalInView: total, nextCursor: next)
    }

    // MARK: - Folder items

    static func itemPage(_ data: Data) throws -> MailItemPage {
        let parsed = try json(data)
        let root = responseItems(parsed).first?["RootFolder"] as? [String: Any] ?? [:]
        let items = (root["Items"] as? [[String: Any]] ?? []).compactMap { dict -> MailListItem? in
            guard let ref = itemRef(dict["ItemId"]) else { return nil }
            return MailListItem(
                ref: ref,
                conversationID: idValue(dict["ConversationId"]),
                subject: (dict["Subject"] as? String) ?? "",
                from: address(dict["From"]) ?? address(dict["Sender"]),
                displayTo: (dict["DisplayTo"] as? String) ?? "",
                received: date(dict["DateTimeReceived"]),
                isRead: bool(dict["IsRead"]),
                hasAttachments: bool(dict["HasAttachments"]),
                importance: MailImportance(owaValue: dict["Importance"] as? String),
                preview: MailExternalBanner.strip(previewText(dict["Preview"])).text,
                instanceKey: string(dict["InstanceKey"]),
                kind: MailItemKind(itemClass: dict["ItemClass"] as? String)
            )
        }
        let isLast = bool(root["IncludesLastItemInRange"])
        let next = isLast ? nil : items.last?.instanceKey.map { MailListCursor.after(instanceKey: $0) }
        return MailItemPage(items: items, totalInView: int(root["TotalItemsInView"]), nextCursor: next)
    }

    // MARK: - Messages

    static func attachment(from dict: [String: Any]) -> MailAttachmentInfo? {
        guard let id = idValue(dict["AttachmentId"]) else { return nil }
        let type = dict["__type"] as? String ?? ""
        let name = string(dict["Name"]) ?? "attachment"
        return MailAttachmentInfo(
            id: id,
            name: name,
            contentType: string(dict["ContentType"]) ?? "application/octet-stream",
            size: int(dict["Size"]) ?? 0,
            isInline: bool(dict["IsInline"]),
            contentID: string(dict["ContentId"]),
            isItemAttachment: type.hasPrefix("ItemAttachment")
        )
    }

    static func message(from dict: [String: Any]) -> MailMessage? {
        guard let ref = itemRef(dict["ItemId"]) else { return nil }
        let bodyValue = (dict["UniqueBody"] as? [String: Any]) ?? (dict["NormalizedBody"] as? [String: Any]) ?? (dict["Body"] as? [String: Any])
        let html: String? = {
            guard let value = bodyValue?["Value"] as? String else { return nil }
            if (bodyValue?["BodyType"] as? String) == "Text" {
                return "<div style=\"white-space: pre-wrap\">\(RichTextHTML.escape(value))</div>"
            }
            return value
        }()
        let to = addresses(dict["ToRecipients"])
        let cc = addresses(dict["CcRecipients"])
        let bcc = addresses(dict["BccRecipients"])
        let counts = dict["RecipientCounts"] as? [String: Any] ?? [:]
        let declared = counts.values.compactMap(int).reduce(0, +)
        let hidden = max(0, declared - to.count - cc.count - bcc.count)
        let actions = Set((dict["ResponseObjects"] as? [[String: Any]] ?? []).compactMap { object in
            (object["__type"] as? String).flatMap(MailAction.init(responseObjectType:))
        })
        let itemClass = dict["ItemClass"] as? String
        let kind = MailItemKind(itemClass: itemClass, hasIrm: bool(dict["HasIrm"]) && html == nil)
        let meeting: MailMeetingInfo? = {
            switch kind {
            case .meetingRequest, .meetingCancellation, .meetingResponse:
                return MailMeetingInfo(
                    start: date(dict["Start"]),
                    end: date(dict["End"]),
                    location: string((dict["Location"] as? [String: Any])?["DisplayName"]) ?? string(dict["Location"]),
                    associatedCalendarItemID: idValue(dict["AssociatedCalendarItemId"]),
                    response: MailMeetingInfo.response(itemClass: itemClass)
                )
            default:
                return nil
            }
        }()
        return MailMessage(
            ref: ref,
            conversationID: idValue(dict["ConversationId"]),
            parentFolderID: idValue(dict["ParentFolderId"]),
            kind: kind,
            subject: (dict["Subject"] as? String) ?? "",
            from: address(dict["From"]) ?? address(dict["Sender"]),
            to: to,
            cc: cc,
            bcc: bcc,
            hiddenRecipientCount: hidden,
            received: date(dict["DateTimeReceived"]),
            sent: date(dict["DateTimeSent"]),
            isRead: bool(dict["IsRead"]),
            isDraft: bool(dict["IsDraft"]),
            importance: MailImportance(owaValue: dict["Importance"] as? String),
            bodyHTML: html,
            preview: previewText(dict["Preview"]),
            attachments: (dict["Attachments"] as? [[String: Any]] ?? []).compactMap(attachment(from:)),
            categories: categories(dict["Categories"]),
            isFlagged: isFlagged(dict["Flag"]),
            actions: actions,
            meeting: meeting,
            internetMessageID: string(dict["InternetMessageId"]),
            sender: onBehalfSender(from: address(dict["From"]), sender: address(dict["Sender"]))
        )
    }

    static func thread(_ data: Data, conversationID: String) throws -> MailThread {
        let parsed = try json(data)
        let conversation = responseItems(parsed).first?["Conversation"] as? [String: Any] ?? [:]
        let nodes = conversation["ConversationNodes"] as? [[String: Any]] ?? []
        let messages = nodes
            .flatMap { ($0["Items"] as? [[String: Any]]) ?? [] }
            .compactMap(message(from:))
            .sorted { ($0.received ?? .distantPast) > ($1.received ?? .distantPast) }
        let total = int(conversation["TotalConversationNodesCount"]) ?? messages.count
        return MailThread(id: idValue(conversation["ConversationId"]) ?? conversationID, messages: messages, totalMessageCount: total)
    }

    static func messages(_ data: Data) throws -> [MailMessage] {
        let parsed = try json(data)
        return responseItems(parsed)
            .flatMap { ($0["Items"] as? [[String: Any]]) ?? [] }
            .compactMap(message(from:))
    }

    /// New ids and change keys from `UpdateItem` / `MoveItem`, in request order.
    static func updatedRefs(_ data: Data) throws -> [MailItemRef] {
        let parsed = try json(data)
        return responseItems(parsed).compactMap { item in
            ((item["Items"] as? [[String: Any]])?.first).flatMap { itemRef($0["ItemId"]) }
        }
    }

    // MARK: - Search

    static func folderRefinerID(fromQuery query: String) -> String? {
        let marker = "folderid:"
        guard let range = query.range(of: marker, options: .caseInsensitive) else { return nil }
        let value = query[range.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        return value.isEmpty ? nil : value
    }

    static func searchPage(_ data: Data, offset: Int) throws -> MailSearchPage {
        let results = body(try json(data))["SearchResults"] as? [String: Any] ?? [:]
        // No results arrive as `null`, not as an empty array.
        let conversations = (results["Conversations"] as? [[String: Any]] ?? []).compactMap(conversation(from:))
        let refiners = (results["SearchRefiners"] as? [[String: Any]] ?? []).compactMap { dict -> MailSearchRefiner? in
            let type = dict["__type"] as? String ?? ""
            let count = int(dict["ResultCount"]) ?? 0
            let query = ((dict["Refiner"] as? [String: Any])?["RefinerQuery"] as? String) ?? ""
            if type.hasPrefix("PeopleRefinerType"), let email = string(dict["SmtpAddress"]) {
                return .sender(name: (dict["DisplayName"] as? String) ?? email, email: email, count: count)
            }
            if type.hasPrefix("AttachmentRefinerType") {
                return .attachments(has: bool(dict["HasAttachment"]), count: count)
            }
            if type.hasPrefix("FolderRefinerType"), let refinerID = folderRefinerID(fromQuery: query) {
                return .folder(refinerID: refinerID, folderID: idValue(dict["FolderId"]), count: count)
            }
            return nil
        }
        return MailSearchPage(
            conversations: conversations,
            moreAvailable: bool(results["MoreResultsAvailable"]),
            searchTerms: (results["SearchTerms"] as? [Any] ?? []).compactMap { $0 as? String },
            refiners: refiners,
            offset: offset
        )
    }

    // MARK: - EWS

    /// The id of the message `CreateItem` saved (a draft); a sent message reports none.
    static func createdItemRef(fromSOAP body: String) -> MailItemRef? {
        guard let re = try? NSRegularExpression(pattern: #"<t:ItemId Id="([^"]+)"(?: ChangeKey="([^"]+)")?"#) else { return nil }
        let ns = body as NSString
        guard let match = re.firstMatch(in: body, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let id = ns.substring(with: match.range(at: 1))
        let changeKey = match.range(at: 2).location == NSNotFound ? nil : ns.substring(with: match.range(at: 2))
        return MailItemRef(id: id, changeKey: changeKey)
    }

    /// The draft after `CreateAttachment`: attaching changes its change key, which sending
    /// needs. The last attachment carries the latest one.
    static func attachmentRootItemRef(fromSOAP body: String) -> MailItemRef? {
        guard let re = try? NSRegularExpression(pattern: #"<t:AttachmentId\b[^>]*?\bRootItemId="([^"]+)"[^>]*?\bRootItemChangeKey="([^"]+)""#) else { return nil }
        let ns = body as NSString
        guard let match = re.matches(in: body, range: NSRange(location: 0, length: ns.length)).last else { return nil }
        return MailItemRef(id: ns.substring(with: match.range(at: 1)), changeKey: ns.substring(with: match.range(at: 2)))
    }
}
