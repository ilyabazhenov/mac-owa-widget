import Foundation

// Mail as the app sees it. Built from OWA JSON responses by `OWAMailParsers`; nothing here is
// ever written to disk (see docs/superpowers/specs/2026-10-17-mail-design.md, "Писем на диске нет").

/// An Exchange item id with the change key that the next modification of it needs.
struct MailItemRef: Hashable, Sendable, Codable {
    let id: String
    let changeKey: String?
}

/// A message to change and what it is: Exchange binds a change by the item type the request names.
struct MailItemTarget: Hashable, Sendable {
    let ref: MailItemRef
    let kind: MailItemKind

    init(_ ref: MailItemRef, kind: MailItemKind) {
        self.ref = ref
        self.kind = kind
    }
}

struct MailAddress: Hashable, Sendable {
    let name: String
    let email: String?

    /// Name for display; the address when the sender has no name.
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return email ?? ""
    }
}

enum MailImportance: String, Sendable {
    case low = "Low"
    case normal = "Normal"
    case high = "High"

    init(owaValue: String?) {
        self = MailImportance(rawValue: owaValue ?? "") ?? .normal
    }
}

/// What can be done with a message, from its `ResponseObjects`.
enum MailAction: String, Hashable, Sendable {
    case reply
    case replyAll
    case forward
    case acceptMeeting
    case tentativelyAcceptMeeting
    case declineMeeting

    init?(responseObjectType: String) {
        let name = responseObjectType.components(separatedBy: ":").first ?? responseObjectType
        switch name {
        case "ReplyToItem": self = .reply
        case "ReplyAllToItem": self = .replyAll
        case "ForwardItem": self = .forward
        case "AcceptItem": self = .acceptMeeting
        case "TentativelyAcceptItem": self = .tentativelyAcceptMeeting
        case "DeclineItem": self = .declineMeeting
        default: return nil
        }
    }
}

/// Distinguished names of the system folders this app knows about.
enum MailDistinguishedFolder: String, CaseIterable, Sendable {
    case inbox
    case drafts
    case sentitems
    case deleteditems
    case junkemail
    case archive
    case outbox
    case msgfolderroot
}

struct MailFolder: Identifiable, Hashable, Sendable {
    let id: String
    let distinguishedID: String?
    let displayName: String
    let parentID: String?
    var unreadCount: Int
    var totalCount: Int
    let childFolderCount: Int

    var distinguished: MailDistinguishedFolder? { distinguishedID.flatMap(MailDistinguishedFolder.init(rawValue:)) }
}

/// How a message is wrapped: ordinary mail, a meeting message, or something only OWA can open.
enum MailItemKind: Sendable, Hashable {
    case note
    case meetingRequest
    case meetingResponse
    case meetingCancellation
    /// IRM- or S/MIME-protected: the body is not readable here.
    case protected
    /// An Enterprise Vault shortcut: the body is a stub, the message lives in the archive.
    case archived
    case other(String)

    init(itemClass: String?, hasIrm: Bool = false) {
        let value = itemClass ?? ""
        if hasIrm { self = .protected; return }
        if value.hasPrefix("IPM.Note.EnterpriseVault") { self = .archived; return }
        if value.hasPrefix("IPM.Note.SMIME") || value.hasPrefix("IPM.Note.Microsoft.Rpmsg") { self = .protected; return }
        if value.hasPrefix("IPM.Schedule.Meeting.Request") { self = .meetingRequest; return }
        if value.hasPrefix("IPM.Schedule.Meeting.Canceled") { self = .meetingCancellation; return }
        if value.hasPrefix("IPM.Schedule.Meeting.Resp") { self = .meetingResponse; return }
        if value.isEmpty || value.hasPrefix("IPM.Note") || value.hasPrefix("IPM.Schedule.Meeting.Notification") { self = .note; return }
        self = .other(value)
    }

    var hasReadableBody: Bool {
        switch self {
        case .protected, .archived: false
        default: true
        }
    }

    var isMeetingMessage: Bool {
        switch self {
        case .meetingRequest, .meetingResponse, .meetingCancellation: true
        default: false
        }
    }
}

struct MailConversationSummary: Identifiable, Hashable, Sendable {
    let id: String
    let topic: String
    let senders: [String]
    let recipients: [String]
    let lastDelivery: Date?
    let messageCount: Int
    /// Messages in the whole mailbox, Sent Items included: more than `messageCount` in a folder
    /// means the user has written in this conversation.
    var globalMessageCount: Int = 0
    let unreadCount: Int
    let hasAttachments: Bool
    let importance: MailImportance
    /// Written by the sender: untrusted.
    let preview: String
    let itemRefs: [MailItemRef]
    let categories: [String]
    let isFlagged: Bool
    let isProtected: Bool
    let instanceKey: String?
    /// Where the conversation lives, for search results that span folders.
    let parentFolderID: String?
    /// The sender's address when the server gives it (search results do, folder lists do not).
    var senderEmail: String? = nil
    /// Message classes in the conversation (`IPM.Note`, `IPM.Schedule.Meeting.Request`, ...).
    var itemClasses: [String] = []
    /// The preview opened with the organization's "external sender" warning (stripped from it).
    var hasExternalBanner = false

    var isMeetingRequest: Bool { itemClasses.contains { $0.hasPrefix("IPM.Schedule.Meeting.Request") } }
    var isMeetingCancellation: Bool { itemClasses.contains { $0.hasPrefix("IPM.Schedule.Meeting.Canceled") } }

    /// What every message of the conversation is, when one kind covers them all (as far as
    /// changing them goes); `nil` when an invitation and replies to it share the thread.
    var uniformItemKind: MailItemKind? {
        let kinds = itemClasses.map { MailItemKind(itemClass: $0) }
        guard let first = kinds.first else { return .note }
        return kinds.allSatisfy { $0.isMeetingMessage == first.isMeetingMessage } ? first : nil
    }

    var isUnread: Bool { unreadCount > 0 }
    /// The user has written in this conversation (a reply sits in Sent Items).
    var userHasReplied: Bool { globalMessageCount > messageCount }
    var primarySender: String { senders.first ?? "" }
    var isAutomated: Bool { MailSenderClassifier.isAutomated(name: primarySender, email: senderEmail) }

    func with(unreadCount: Int? = nil, isFlagged: Bool? = nil) -> MailConversationSummary {
        var copy = MailConversationSummary(
            id: id, topic: topic, senders: senders, recipients: recipients, lastDelivery: lastDelivery,
            messageCount: messageCount, globalMessageCount: globalMessageCount, unreadCount: unreadCount ?? self.unreadCount,
            hasAttachments: hasAttachments, importance: importance, preview: preview, itemRefs: itemRefs, categories: categories,
            isFlagged: isFlagged ?? self.isFlagged, isProtected: isProtected, instanceKey: instanceKey, parentFolderID: parentFolderID
        )
        copy.senderEmail = senderEmail
        copy.itemClasses = itemClasses
        copy.hasExternalBanner = hasExternalBanner
        return copy
    }
}

/// Tells mail from people apart from mail sent by systems (CI, trackers, monitoring, bulk
/// senders). A heuristic over the name and address only: no content is read.
/// The warning transport rules put at the top of mail from outside the organization. In a
/// preview it hides the actual text, so it is cut out and shown as an "external" tag instead.
enum MailExternalBanner {
    private static let patterns = [
        "^Внешний отправитель!?\\s*Будьте осторожны с вложениями и ссылками[.!]?",
        "^\\[(EXTERNAL|ВНЕШНИЙ|ВНЕШНЕЕ)\\]",
    ]

    static func strip(_ text: String) -> (text: String, found: Bool) {
        // The warning sign comes as "⚠" or the emoji "⚠️" (one grapheme a regex class misses).
        let head = String(text.drop { $0.isWhitespace || $0.unicodeScalars.first?.value == 0x26A0 })
        for pattern in patterns {
            if let range = head.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
                var rest = String(head[range.upperBound...])
                rest = rest.replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
                return (rest.trimmingCharacters(in: .whitespacesAndNewlines), true)
            }
        }
        return (text, false)
    }
}

enum MailSenderClassifier {
    static let automatedNameWords = [
        "bitbucket", "jira", "jenkins", "confluence", "gitlab", "github", "grafana", "prometheus", "alertmanager",
        "sentry", "teamcity", "sonar", "nexus", "kibana", "zabbix", "pagerduty", "opsgenie", "servicenow",
        "noreply", "no-reply", "no_reply", "donotreply", "do-not-reply", "notification", "notifications", "mailer",
        "daemon", "robot", "bot", "alert", "alerts", "monitoring", "system", "info", "news", "newsletter", "digest",
        "postmaster", "support", "helpdesk", "service", "сервис", "робот", "рассылка", "уведомлен", "оповещен",
    ]

    static func isAutomated(name: String, email: String?) -> Bool {
        let candidates = [name, email ?? ""].map { $0.lowercased() }.filter { !$0.isEmpty }
        // A display name that is an address, or a system account name: nobody types those for a person.
        if name.contains("@") || name.lowercased().hasPrefix("etl") { return true }
        for text in candidates {
            let local = text.split(separator: "@").first.map(String.init) ?? text
            let words = local.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            for word in automatedNameWords where words.contains(word) || (word.count > 6 && local.contains(word)) {
                return true
            }
        }
        // People in an address book have a first and a last name. A one-word name ("Appsec",
        // "Контур.Толк", "HR-команда") or one with a word in capitals ("Informatica PROD ETL") is a
        // system, a team box or a product far more often than a person.
        let parts = name.split(whereSeparator: \.isWhitespace)
        if parts.count == 1 { return true }
        if parts.contains(where: { word in
            word.count >= 2 && word.allSatisfy { $0.isLetter && $0.isUppercase }
        }) {
            return true
        }
        return false
    }
}

struct MailAttachmentInfo: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let contentType: String
    let size: Int
    let isInline: Bool
    let contentID: String?
    /// An attached message (`ItemAttachment`): opened in OWA, not here.
    let isItemAttachment: Bool
}

struct MailMeetingInfo: Hashable, Sendable {
    let start: Date?
    let end: Date?
    let location: String?
    let associatedCalendarItemID: String?
}

struct MailMessage: Identifiable, Hashable, Sendable {
    let ref: MailItemRef
    var id: String { ref.id }
    let conversationID: String?
    let parentFolderID: String?
    let kind: MailItemKind
    let subject: String
    let from: MailAddress?
    let to: [MailAddress]
    let cc: [MailAddress]
    let bcc: [MailAddress]
    /// Recipients the server left out (`MaximumRecipientsToReturn`).
    let hiddenRecipientCount: Int
    let received: Date?
    let sent: Date?
    let isRead: Bool
    let isDraft: Bool
    let importance: MailImportance
    /// Server-filtered HTML: `UniqueBody` in a thread, `NormalizedBody` for a single message.
    let bodyHTML: String?
    let preview: String
    let attachments: [MailAttachmentInfo]
    let categories: [String]
    let isFlagged: Bool
    let actions: Set<MailAction>
    let meeting: MailMeetingInfo?
    let internetMessageID: String?

    var visibleAttachments: [MailAttachmentInfo] { attachments.filter { !$0.isInline } }

    func with(ref: MailItemRef? = nil, isRead: Bool? = nil, categories: [String]? = nil, isFlagged: Bool? = nil) -> MailMessage {
        MailMessage(
            ref: ref ?? self.ref, conversationID: conversationID, parentFolderID: parentFolderID, kind: kind,
            subject: subject, from: from, to: to, cc: cc, bcc: bcc, hiddenRecipientCount: hiddenRecipientCount,
            received: received, sent: sent, isRead: isRead ?? self.isRead, isDraft: isDraft, importance: importance,
            bodyHTML: bodyHTML, preview: preview, attachments: attachments, categories: categories ?? self.categories,
            isFlagged: isFlagged ?? self.isFlagged, actions: actions, meeting: meeting, internetMessageID: internetMessageID
        )
    }
}

struct MailThread: Identifiable, Hashable, Sendable {
    let id: String
    /// Newest first.
    let messages: [MailMessage]
    let totalMessageCount: Int

    var topic: String { messages.last?.subject ?? messages.first?.subject ?? "" }
}

/// Paging position for folder lists: the first page, or everything after a known item.
enum MailListCursor: Hashable, Sendable {
    case first
    case after(instanceKey: String)
}

struct MailConversationPage: Sendable {
    let conversations: [MailConversationSummary]
    let totalInView: Int?
    /// `nil` when the folder has nothing more.
    let nextCursor: MailListCursor?
}

/// One message in a folder list (`FindItem`), used for "mail in a period" in MCP.
struct MailListItem: Identifiable, Hashable, Sendable {
    let ref: MailItemRef
    var id: String { ref.id }
    let conversationID: String?
    let subject: String
    let from: MailAddress?
    let displayTo: String
    let received: Date?
    let isRead: Bool
    let hasAttachments: Bool
    let importance: MailImportance
    let preview: String
    let instanceKey: String?
    var kind: MailItemKind = .note
}

/// A batch of conversations the window lists or acts on together.
enum MailListMode: String, CaseIterable, Identifiable, Sendable {
    case all
    case unread

    var id: String { rawValue }
    var serverFilter: MailListFilter { self == .unread ? .unread : .all }
}

struct MailItemPage: Sendable {
    let items: [MailListItem]
    let totalInView: Int?
    let nextCursor: MailListCursor?
}

enum MailListFilter: String, Sendable {
    case all = "All"
    case unread = "Unread"
}

enum MailSearchScope: Hashable, Sendable {
    case mailbox
    case distinguished(MailDistinguishedFolder)
    case folder(id: String)
}

struct MailSearchQuery: Hashable, Sendable {
    var text: String
    var scope: MailSearchScope = .mailbox
    /// SMTP addresses: messages from any of them.
    var from: [String] = []
    var hasAttachments: Bool?
    /// First and last day, inclusive, as dates in the display time zone.
    var receivedFrom: Date?
    var receivedTo: Date?
    /// A server folder refiner (`FolderRefinerId`) taken from an earlier answer.
    var folderRefinerID: String?

    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && from.isEmpty && hasAttachments == nil
            && receivedFrom == nil && receivedTo == nil && folderRefinerID == nil
    }
}

/// A suggestion the server returns with search results: narrow by a sender, a folder or attachments.
enum MailSearchRefiner: Hashable, Sendable {
    case sender(name: String, email: String, count: Int)
    case folder(refinerID: String, folderID: String?, count: Int)
    case attachments(has: Bool, count: Int)
}

struct MailSearchPage: Sendable {
    let conversations: [MailConversationSummary]
    let moreAvailable: Bool
    let searchTerms: [String]
    let refiners: [MailSearchRefiner]
    let offset: Int
}

/// What `UpdateItem` changes on a message.
enum MailItemUpdate: Sendable, Equatable {
    case isRead(Bool)
    case categories([String])
    case flag(MailFlagStatus)
}

enum MailFlagStatus: String, Sendable {
    case notFlagged = "NotFlagged"
    case flagged = "Flagged"
    case complete = "Complete"
}

/// An outgoing message as the user (or the confirmation panel) approved it.
struct MailOutgoing: Sendable, Equatable {
    enum Kind: String, Sendable, Equatable {
        case new
        case reply
        case replyAll
        case forward
    }

    var kind: Kind
    /// The message replied to or forwarded. `nil` for a new message.
    var reference: MailItemRef?
    var to: [String]
    var cc: [String]
    var subject: String
    /// Plain text typed by the user; sent as escaped HTML. Each U+FFFC marks where the next of
    /// `inlineImages` goes, as in the editor's text.
    var body: String
    /// `false` keeps it in Drafts instead of sending.
    var send: Bool = true
    /// Pictures pasted into the text, in order: inline attachments referenced by `cid:`.
    var inlineImages: [MailInlineImage] = []
}

/// A picture pasted into an outgoing message.
struct MailInlineImage: Sendable, Equatable {
    /// Marks where a picture sits in `MailOutgoing.body`, as in an attributed string's text.
    static let placeholder: Character = "\u{FFFC}"
    /// Exchange's usual limit on a whole message is 10 MB after base64 (×4/3), with room for
    /// the text and the quoted history.
    static let maxTotalBytes = 6 * 1024 * 1024

    let contentID: String
    let name: String
    let contentType: String
    let data: Data

    init(contentID: String = UUID().uuidString.lowercased() + "@owawidget", name: String, contentType: String, data: Data) {
        self.contentID = contentID
        self.name = name
        self.contentType = contentType
        self.data = data
    }
}

/// An email saved as a draft and read back from Exchange: who it will really go to.
///
/// For a reply Exchange works the recipients out itself (the original's Reply-To, everyone on a
/// reply-all) and may add them to the ones asked for. Sending the draft only after reading it
/// back means what the user approves is exactly what goes out.
struct MailPreparedSend: Sendable, Equatable {
    let draft: MailItemRef
    let outgoing: MailOutgoing
    let to: [MailAddress]
    let cc: [MailAddress]
    let bcc: [MailAddress]
    let attachments: [MailAttachmentInfo]

    var recipients: [MailAddress] { to + cc + bcc }

    /// Recipients the server put on the draft beyond the ones asked for. One without an address
    /// counts too: what cannot be matched cannot be taken as approved.
    var addedRecipients: [MailAddress] {
        let requested = Set((outgoing.to + outgoing.cc).map { $0.lowercased() })
        return recipients.filter { address in
            guard let email = address.email?.lowercased() else { return true }
            return !requested.contains(email)
        }
    }

    /// Recipients asked for that the server left off.
    var droppedRecipients: [String] {
        let present = Set(recipients.compactMap { $0.email?.lowercased() })
        return (outgoing.to + outgoing.cc).filter { !present.contains($0.lowercased()) }
    }

    /// Exchange's list is exactly the one asked for.
    var matchesRequest: Bool { addedRecipients.isEmpty && droppedRecipients.isEmpty }

    /// Reads a review draft into what will be sent; refuses a list the server cut short.
    static func make(draft message: MailMessage, outgoing: MailOutgoing) throws -> MailPreparedSend {
        guard message.hiddenRecipientCount == 0 else { throw MailError.recipientsUnverified }
        return MailPreparedSend(
            draft: message.ref, outgoing: outgoing,
            to: message.to, cc: message.cc, bcc: message.bcc,
            attachments: message.attachments
        )
    }
}

enum MailError: LocalizedError, Equatable {
    case notSupported
    case notFound
    case blocked(String)
    case serverError(String)
    case tooLarge(Int)
    /// The connection broke while Exchange had the send request: it may have gone out.
    case sendUncertain
    /// The server would not list every recipient of the draft, so it cannot be shown in full.
    case recipientsUnverified

    var errorDescription: String? {
        switch self {
        case .sendUncertain: "The connection broke while sending: the email may have gone out. Check Sent Items before sending again."
        case .recipientsUnverified: "Exchange did not list every recipient of this email, so it was not sent. Open it in OWA to check the recipients."
        case .notSupported: "Mail is not available for this account"
        case .notFound: "The message was not found. It may have been moved or deleted."
        case .blocked(let reason): reason
        case .serverError(let code): "Exchange error: \(code)"
        case .tooLarge(let size): "The attachment is too large (\(size) bytes)"
        }
    }
}
