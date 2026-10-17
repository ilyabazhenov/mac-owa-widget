import Foundation

/// A folder as a request names it: a system folder by its distinguished name, or any folder by id.
enum MailFolderRef: Hashable, Sendable {
    case distinguished(MailDistinguishedFolder)
    case id(String)

    var isSentItems: Bool {
        if case .distinguished(.sentitems) = self { return true }
        return false
    }
}

/// Mail of one account. Separate from `CalendarProvider`: EventKit has no mail, and only an
/// Exchange account (`AccountType.supportsMail`) implements it.
///
/// Implementations share the account's single network session with the calendar: a second
/// session with the same credentials would bypass the circuit breaker.
protocol MailProvider: Actor {
    nonisolated var account: CalendarAccount { get }

    /// The mail folder tree. Heavy (the whole OWA session data): call once per session.
    func mailFolders() async throws -> [MailFolder]
    /// Unread and total counts. The only request made periodically.
    func mailFolderCounts(_ folders: [MailFolderRef]) async throws -> [MailFolder]
    func mailConversations(in folder: MailFolderRef, cursor: MailListCursor, filter: MailListFilter) async throws -> MailConversationPage
    func mailItems(in folder: MailFolderRef, cursor: MailListCursor, filter: MailListFilter, count: Int) async throws -> MailItemPage
    /// The messages of a conversation, newest first, without those in `ignoringFolders`.
    func mailThread(conversationID: String, ignoringFolders: [String]) async throws -> MailThread
    /// One message in full (with the quoted history). Does not mark it as read.
    func mailMessage(_ ref: MailItemRef) async throws -> MailMessage
    func mailAttachment(id: String, maxBytes: Int) async throws -> Data
    /// One request for all `refs`; returns their new ids and change keys, in order.
    func mailUpdate(_ refs: [MailItemRef], _ update: MailItemUpdate) async throws -> [MailItemRef]
    /// Returns the new ids: a moved item gets a new one.
    func mailMove(_ refs: [MailItemRef], to folder: MailFolderRef) async throws -> [MailItemRef]
    func mailSearch(_ query: MailSearchQuery, offset: Int, count: Int) async throws -> MailSearchPage
    func mailEndSearch() async
    /// Sends (or saves to Drafts) through EWS. Returns the saved draft's id, if any.
    func mailSend(_ outgoing: MailOutgoing) async throws -> MailItemRef?
}
