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
    /// Several conversations in one request, in order, without the messages in
    /// `ignoringFolders`: one the server cannot find fails on its own.
    func mailThreads(conversationIDs: [String], ignoringFolders: [String]) async throws -> [Result<MailThread, MailError>]
    /// One request for all `targets`; returns their new ids and change keys, in order.
    func mailUpdate(_ targets: [MailItemTarget], _ update: MailItemUpdate) async throws -> [MailItemRef]
    /// `mailUpdate` item by item: Exchange applies the other items when one fails, and this
    /// says which did. Throws only when the request as a whole failed.
    func mailUpdateEach(_ targets: [MailItemTarget], _ update: MailItemUpdate) async throws -> [Result<MailItemRef, MailError>]
    /// Returns the new ids: a moved item gets a new one.
    func mailMove(_ refs: [MailItemRef], to folder: MailFolderRef) async throws -> [MailItemRef]
    /// `mailMove` item by item, in request order: the id each message got in `folder` (a move
    /// changes it), or why that one did not move.
    func mailMoveEach(_ refs: [MailItemRef], to folder: MailFolderRef) async throws -> [Result<MailItemRef, MailError>]
    func mailSearch(_ query: MailSearchQuery, offset: Int, count: Int) async throws -> MailSearchPage
    /// A page in the search session already open for the query's scope: one request, or `nil`
    /// without any when none is open (another search may have ended or replaced it). For the
    /// requests of a search after its first page, and checks next to it, such as how much each
    /// word finds alone: they must not cost a new session.
    func mailSearchInOpenSession(_ query: MailSearchQuery, offset: Int, count: Int) async throws -> MailSearchPage?
    func mailEndSearch() async
    /// Sends (or saves to Drafts) through EWS. Returns the saved draft's id, if any.
    func mailSend(_ outgoing: MailOutgoing) async throws -> MailItemRef?
    /// The draft as the server holds it, with every recipient: what sending it would send.
    func mailDraftForReview(_ ref: MailItemRef) async throws -> MailMessage
    /// Sends a draft as it is on the server. Never repeated on a broken connection.
    func mailSendDraft(_ ref: MailItemRef) async throws
    /// Deletes a review draft the user did not send.
    func mailDeleteDraft(_ ref: MailItemRef) async throws
}

/// One request per conversation and all-or-nothing updates: what a provider without batched
/// requests (and the test fakes) does. The Exchange provider batches both.
extension MailProvider {
    func mailSearchInOpenSession(_ query: MailSearchQuery, offset: Int, count: Int) async throws -> MailSearchPage? {
        try await mailSearch(query, offset: offset, count: count)
    }

    func mailThreads(conversationIDs: [String], ignoringFolders: [String]) async throws -> [Result<MailThread, MailError>] {
        var results: [Result<MailThread, MailError>] = []
        for id in conversationIDs {
            do {
                results.append(.success(try await mailThread(conversationID: id, ignoringFolders: ignoringFolders)))
            } catch let error as MailError {
                results.append(.failure(error))
            }
        }
        return results
    }

    /// Without per-item answers a short reply cannot say which message moved where: then none
    /// of them is reported moved, though some may have been.
    func mailMoveEach(_ refs: [MailItemRef], to folder: MailFolderRef) async throws -> [Result<MailItemRef, MailError>] {
        do {
            let moved = try await mailMove(refs, to: folder)
            guard moved.count == refs.count else { return refs.map { _ in .failure(.serverError("PartialMove")) } }
            return moved.map { .success($0) }
        } catch let error as MailError {
            return refs.map { _ in .failure(error) }
        }
    }

    func mailUpdateEach(_ targets: [MailItemTarget], _ update: MailItemUpdate) async throws -> [Result<MailItemRef, MailError>] {
        do {
            let refs = try await mailUpdate(targets, update)
            return targets.indices.map { .success($0 < refs.count ? refs[$0] : targets[$0].ref) }
        } catch let error as MailError {
            return targets.map { _ in .failure(error) }
        }
    }
}
