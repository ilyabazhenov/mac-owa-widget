import Foundation
import os.log

/// An open OWA search session: `ExecuteSearch` pages through results within one.
struct OWAMailSearchSession: Sendable {
    let id: String
    let scope: MailSearchScope
}

/// Mail over the same session as the calendar: OWA JSON (`service.svc`) for reading and for
/// state changes in the user's own mailbox, EWS SOAP for anything that leaves it.
/// Formats: docs/superpowers/specs/2026-10-17-mail-design.md.
extension OWAClient {
    /// Largest attachment fetched into memory.
    static let mailAttachmentLimit = 25 * 1024 * 1024

    #if DEBUG
    private nonisolated static let mailTraceName = "mail.log"

    private nonisolated func mailTrace(_ message: String) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        DebugLogLocation.append("[\(f.string(from: Date()))] \(message)\n", to: Self.mailTraceName)
    }
    #endif

    // MARK: - Transport

    /// One `service.svc` call with the JSON body in the POST body (as `FindPeople` and
    /// `GetCalendarEvent` already do), re-authenticating once on a stale session.
    func mailServiceCall(action: String, payload: [String: Any], attempt: Int = 0) async throws -> Data {
        let canary = try await ensureCanary()
        try Task.checkCancellation()

        guard var components = URLComponents(url: try url("/owa/service.svc"), resolvingAgainstBaseURL: false) else {
            throw OWAError.invalidURL("/owa/service.svc")
        }
        components.queryItems = [
            URLQueryItem(name: "action", value: action),
            URLQueryItem(name: "EP", value: "1"),
            URLQueryItem(name: "ID", value: "-\(Int.random(in: 100...999))"),
            URLQueryItem(name: "AC", value: "1"),
        ]
        guard let serviceURL = components.url else { throw OWAError.invalidURL("/owa/service.svc") }

        var request = URLRequest(url: serviceURL, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.httpBody = Data(Self.serializeJSONTypeFirst(payload).utf8)
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue(canary, forHTTPHeaderField: "X-OWA-CANARY")
        request.setValue(action, forHTTPHeaderField: "Action")
        request.setValue(action, forHTTPHeaderField: "X-OWA-ActionName")
        request.setValue("1", forHTTPHeaderField: "X-OWA-Attempt")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue(baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")), forHTTPHeaderField: "Origin")
        let correlationID = Self.makeCorrelationId()
        request.setValue(correlationID, forHTTPHeaderField: "X-OWA-CorrelationId")
        request.setValue(correlationID, forHTTPHeaderField: "client-request-id")
        request.setValue(Self.iso8601Millis(Date()), forHTTPHeaderField: "X-OWA-ClientBegin")
        addCommonHeaders(&request)

        let started = Date()
        let (data, response) = try await sessionDataAllowingStaleReconnect(for: request)
        guard let http = response as? HTTPURLResponse else { throw OWAError.invalidResponse }
        let durationMS = Int(Date().timeIntervalSince(started) * 1000)
        log.info("OWA mail request action=\(action, privacy: .public) status=\(http.statusCode, privacy: .public) bytes=\(data.count, privacy: .public) durationMs=\(durationMS, privacy: .public)")
        #if DEBUG
        mailTrace("\(action) status=\(http.statusCode) bytes=\(data.count) ms=\(durationMS)")
        // The last answer per action, encrypted like every other trace; overwritten each time.
        DebugLogLocation.write(data, to: "mail-\(action.lowercased())-last.json")
        #endif

        if OWAError.isSessionStaleStatus(http.statusCode) {
            canaryToken = nil
            guard attempt < 1 else { throw OWAError.httpError(http.statusCode, "\(action) auth retry exhausted") }
            try await authenticate()
            return try await mailServiceCall(action: action, payload: payload, attempt: attempt + 1)
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data.prefix(300), encoding: .utf8) ?? ""
            log.warning("OWA mail request failed action=\(action, privacy: .public) status=\(http.statusCode, privacy: .public) responseKind=\(OWAError.diagnosticResponseKind(from: message), privacy: .public)")
            throw OWAError.httpError(http.statusCode, message)
        }
        return data
    }

    private func folderJSON(_ folder: MailFolderRef) -> [String: Any] {
        switch folder {
        case .distinguished(let name): OWAMailPayloads.distinguishedFolderID(name)
        case .id(let id): OWAMailPayloads.folderID(id)
        }
    }

    // MARK: - Folders

    func mailFolders() async throws -> [MailFolder] {
        do {
            let data = try await sessionData()
            let json = try JSONSerialization.jsonObject(with: data)
            let tree = (json as? [String: Any])?["findFolders"] ?? json
            let folders = OWAMailParsers.folders(in: tree)
            if folders.contains(where: { $0.distinguished == .inbox }) { return folders }
            log.warning("sessiondata returned no inbox; falling back to GetFolder")
        } catch let error as OWAError where OWAError.isAuthError(error) {
            throw error
        } catch {
            log.warning("sessiondata failed (\(error.localizedDescription, privacy: .private)); falling back to GetFolder")
        }
        // The system folders alone, by distinguished name.
        let system: [MailDistinguishedFolder] = [.inbox, .drafts, .sentitems, .deleteditems, .junkemail, .archive]
        var result: [MailFolder] = []
        for name in system {
            // One per request: a mailbox without `archive` fails the whole batch otherwise.
            let payload = OWAMailPayloads.getFolder(folders: [OWAMailPayloads.distinguishedFolderID(name)], withNames: true, timeZoneID: windowsTimezoneID())
            let data: Data
            do {
                data = try await mailServiceCall(action: "GetFolder", payload: payload)
            } catch {
                // Only a folder this mailbox lacks is skipped. Sign-in, certificate and login-host
                // errors go up: swallowed, every iteration would sign in again (one more bad
                // password attempt each) and the breaker would never see why.
                if Self.isFolderLevelError(error) { continue }
                throw error
            }
            guard let json = try? OWAMailParsers.json(data),
                  let folder = OWAMailParsers.folders(in: json).first else { continue }
            result.append(MailFolder(
                id: folder.id, distinguishedID: name.rawValue,
                displayName: folder.displayName.isEmpty ? name.rawValue : folder.displayName,
                parentID: nil, unreadCount: folder.unreadCount, totalCount: folder.totalCount, childFolderCount: folder.childFolderCount
            ))
        }
        guard !result.isEmpty else { throw OWAError.invalidResponse }
        return result
    }

    /// An error about one folder (missing in this mailbox, refused by the server), not about the
    /// session or the connection.
    static func isFolderLevelError(_ error: Error) -> Bool {
        if OWAError.isAuthError(error) { return false }
        switch error as? OWAError {
        case .httpError(let code, _): return code != 449 && code < 500
        case .invalidResponse: return true
        default:
            if case .blocked = error as? MailError { return false }
            return error is MailError
        }
    }

    /// `sessiondata.ashx`: the session bootstrap the OWA page loads first. Its `findFolders`
    /// part is the whole folder tree with counts.
    private func sessionData(attempt: Int = 0) async throws -> Data {
        let canary = try await ensureCanary()
        var request = URLRequest(url: try url("/owa/sessiondata.ashx?appcacheclient=0"), timeoutInterval: 30)
        request.httpMethod = "POST"
        request.httpBody = Data()
        request.setValue(canary, forHTTPHeaderField: "X-OWA-CANARY")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        addCommonHeaders(&request)
        let (data, response) = try await sessionDataAllowingStaleReconnect(for: request)
        guard let http = response as? HTTPURLResponse else { throw OWAError.invalidResponse }
        log.info("OWA sessiondata status=\(http.statusCode, privacy: .public) bytes=\(data.count, privacy: .public)")
        if OWAError.isSessionStaleStatus(http.statusCode) {
            canaryToken = nil
            guard attempt < 1 else { throw OWAError.httpError(http.statusCode, "sessiondata auth retry exhausted") }
            try await authenticate()
            return try await sessionData(attempt: attempt + 1)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw OWAError.httpError(http.statusCode, String(data: data.prefix(300), encoding: .utf8) ?? "")
        }
        return data
    }

    func mailFolderCounts(_ folders: [MailFolderRef]) async throws -> [MailFolder] {
        guard !folders.isEmpty else { return [] }
        let payload = OWAMailPayloads.getFolder(folders: folders.map(folderJSON), withNames: false, timeZoneID: windowsTimezoneID())
        let data = try await mailServiceCall(action: "GetFolder", payload: payload)
        return OWAMailParsers.folders(in: try OWAMailParsers.json(data))
    }

    // MARK: - Lists and reading

    func mailConversations(in folder: MailFolderRef, cursor: MailListCursor, filter: MailListFilter) async throws -> MailConversationPage {
        let payload = OWAMailPayloads.findConversation(
            folder: folderJSON(folder), cursor: cursor, filter: filter, sentItems: folder.isSentItems, timeZoneID: windowsTimezoneID()
        )
        let data = try await mailServiceCall(action: "FindConversation", payload: payload)
        return try OWAMailParsers.conversationPage(data, requested: OWAMailPayloads.pageSize)
    }

    func mailItems(in folder: MailFolderRef, cursor: MailListCursor, filter: MailListFilter, count: Int) async throws -> MailItemPage {
        let payload = OWAMailPayloads.findItem(folder: folderJSON(folder), cursor: cursor, filter: filter, count: count, timeZoneID: windowsTimezoneID())
        let data = try await mailServiceCall(action: "FindItem", payload: payload)
        return try OWAMailParsers.itemPage(data)
    }

    func mailThread(conversationID: String, ignoringFolders: [String]) async throws -> MailThread {
        let payload = OWAMailPayloads.getConversationItems(
            conversationID: conversationID, foldersToIgnore: ignoringFolders, timeZoneID: windowsTimezoneID()
        )
        let data = try await mailServiceCall(action: "GetConversationItems", payload: payload)
        return try OWAMailParsers.thread(data, conversationID: conversationID)
    }

    func mailMessage(_ ref: MailItemRef) async throws -> MailMessage {
        let data = try await mailServiceCall(action: "GetItem", payload: OWAMailPayloads.getItem(ref, timeZoneID: windowsTimezoneID()))
        guard let message = try OWAMailParsers.messages(data).first else { throw MailError.notFound }
        return message
    }

    /// Downloads an attachment. The URL carries the CANARY, so it is never logged.
    func mailAttachment(id: String, maxBytes: Int, attempt: Int = 0) async throws -> Data {
        let canary = try await ensureCanary()
        guard var components = URLComponents(url: try url("/owa/service.svc/s/GetFileAttachment"), resolvingAgainstBaseURL: false) else {
            throw OWAError.invalidURL("GetFileAttachment")
        }
        components.queryItems = [URLQueryItem(name: "id", value: id), URLQueryItem(name: "X-OWA-CANARY", value: canary)]
        // `+` and `/` are base64 in the id: `URLComponents` leaves `+`, which the server would read as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let attachmentURL = components.url else { throw OWAError.invalidURL("GetFileAttachment") }
        var request = URLRequest(url: attachmentURL, timeoutInterval: 60)
        request.httpMethod = "GET"
        addCommonHeaders(&request)
        let (data, response) = try await sessionDataAllowingStaleReconnect(for: request)
        guard let http = response as? HTTPURLResponse else { throw OWAError.invalidResponse }
        log.info("OWA attachment status=\(http.statusCode, privacy: .public) bytes=\(data.count, privacy: .public)")
        if OWAError.isSessionStaleStatus(http.statusCode) {
            canaryToken = nil
            guard attempt < 1 else { throw OWAError.httpError(http.statusCode, "GetFileAttachment auth retry exhausted") }
            try await authenticate()
            return try await mailAttachment(id: id, maxBytes: maxBytes, attempt: attempt + 1)
        }
        guard (200..<300).contains(http.statusCode) else { throw OWAError.httpError(http.statusCode, "GetFileAttachment") }
        guard data.count <= maxBytes else { throw MailError.tooLarge(data.count) }
        return data
    }

    // MARK: - Changes in the user's own mailbox

    func mailUpdate(_ targets: [MailItemTarget], _ update: MailItemUpdate) async throws -> [MailItemRef] {
        guard !targets.isEmpty else { return [] }
        let data = try await mailServiceCall(action: "UpdateItem", payload: OWAMailPayloads.updateItems(targets, update: update, timeZoneID: windowsTimezoneID()))
        let updated = try OWAMailParsers.updatedRefs(data)
        return updated.count == targets.count ? updated : targets.map(\.ref)
    }

    func mailMove(_ refs: [MailItemRef], to folder: MailFolderRef) async throws -> [MailItemRef] {
        guard !refs.isEmpty else { return [] }
        let data = try await mailServiceCall(action: "MoveItem", payload: OWAMailPayloads.moveItems(refs, to: folderJSON(folder), timeZoneID: windowsTimezoneID()))
        return try OWAMailParsers.updatedRefs(data)
    }

    // MARK: - Search

    /// Runs a search page inside a session for the query's scope, opening one when needed.
    /// The search history OWA keeps in the mailbox (`UpdateUserConfiguration`) is not touched.
    func mailSearch(_ query: MailSearchQuery, offset: Int, count: Int) async throws -> MailSearchPage {
        let zone = windowsTimezoneID()
        if mailSearchSession?.scope != query.scope || offset == 0 {
            await mailEndSearch()
            let sessionID = UUID().uuidString.lowercased()
            _ = try await mailServiceCall(
                action: "StartSearchSession",
                payload: OWAMailPayloads.startSearchSession(sessionID: sessionID, scope: query.scope, timeZoneID: zone)
            )
            mailSearchSession = OWAMailSearchSession(id: sessionID, scope: query.scope)
        }
        guard let session = mailSearchSession else { throw OWAError.invalidResponse }
        let payload = OWAMailPayloads.executeSearch(
            sessionID: session.id, query: query, offset: offset, count: count, calendar: AppTimeZone.calendar, timeZoneID: zone
        )
        let data = try await mailServiceCall(action: "ExecuteSearch", payload: payload)
        return try OWAMailParsers.searchPage(data, offset: offset)
    }

    func mailEndSearch() async {
        guard let session = mailSearchSession else { return }
        mailSearchSession = nil
        _ = try? await mailServiceCall(
            action: "EndSearchSession",
            payload: OWAMailPayloads.endSearchSession(sessionID: session.id, timeZoneID: windowsTimezoneID())
        )
    }

    // MARK: - Sending (EWS)

    /// `CreateItem` through EWS. Used for drafts: sending goes draft → review → `mailSendDraft`.
    /// A save that is dropped and repeated at worst leaves a second draft, never a second email;
    /// an outright send (`send == true`) is never repeated automatically.
    func mailSend(_ outgoing: MailOutgoing) async throws -> MailItemRef? {
        do {
            return try await createMessage(outgoing)
        } catch OWAError.ewsError("ErrorStaleObject") where outgoing.reference != nil {
            // The original changed after the reply window took it (marked read, flagged, a
            // reply in another client): Exchange refuses a reply to an older version and creates
            // nothing. Once more against its current change key.
            let current = try await mailMessage(MailItemRef(id: outgoing.reference!.id, changeKey: nil)).ref
            DiagnosticLog.event("Mail CreateItem stale reference, retrying with the current change key")
            var retry = outgoing
            retry.reference = current
            return try await createMessage(retry)
        }
    }

    /// With pasted pictures the message is always saved first, the pictures attached to the draft
    /// and only then sent: a reply or a forward cannot carry them in `CreateItem` itself.
    private func createMessage(_ outgoing: MailOutgoing) async throws -> MailItemRef? {
        var draft = outgoing
        if !outgoing.inlineImages.isEmpty { draft.send = false }
        let body = try await ewsCall(
            action: "CreateItem",
            soap: OWAMailPayloads.createMessageSOAP(draft),
            mayRepeat: !draft.send,
            note: "kind=\(outgoing.kind.rawValue) send=\(draft.send) to=\(outgoing.to.count) cc=\(outgoing.cc.count) images=\(outgoing.inlineImages.count)"
        )
        let created = OWAMailParsers.createdItemRef(fromSOAP: body)
        guard !outgoing.inlineImages.isEmpty else { return created }
        guard let created else { throw MailError.serverError("no draft id") }
        let ref: MailItemRef
        do {
            ref = try await attachInlineImages(outgoing.inlineImages, to: created)
        } catch {
            // A draft without its pictures would show empty frames: it goes, and the user retries.
            try? await mailDeleteDraft(created)
            throw error
        }
        if outgoing.send {
            try await mailSendDraft(ref)
            return nil
        }
        return ref
    }

    /// Repeating it is harmless at worst (a picture attached twice to an unsent draft).
    private func attachInlineImages(_ images: [MailInlineImage], to draft: MailItemRef) async throws -> MailItemRef {
        let body = try await ewsCall(
            action: "CreateAttachment",
            // No change key: a repeat after a lost answer would be refused as stale.
            soap: OWAMailPayloads.createInlineAttachmentsSOAP(parent: MailItemRef(id: draft.id, changeKey: nil), images: images),
            mayRepeat: true,
            note: "count=\(images.count) bytes=\(images.reduce(0) { $0 + $1.data.count })"
        )
        guard let updated = OWAMailParsers.attachmentRootItemRef(fromSOAP: body) else {
            // Without the new change key `SendItem` would be refused as stale.
            return try await mailMessage(MailItemRef(id: draft.id, changeKey: nil)).ref
        }
        return updated
    }

    /// The draft as Exchange holds it, every recipient included: what will actually be sent.
    func mailDraftForReview(_ ref: MailItemRef) async throws -> MailMessage {
        let payload = OWAMailPayloads.getItem(ref, timeZoneID: windowsTimezoneID(), allRecipients: true)
        let data = try await mailServiceCall(action: "GetItem", payload: payload)
        guard let message = try OWAMailParsers.messages(data).first else { throw MailError.notFound }
        return message
    }

    /// Sends a reviewed draft. Never repeated after a broken connection: Exchange may already
    /// have sent it, so that is reported as uncertain instead of risking a second copy.
    func mailSendDraft(_ ref: MailItemRef) async throws {
        _ = try await ewsCall(action: "SendItem", soap: OWAMailPayloads.sendItemSOAP(ref), mayRepeat: false, note: "")
    }

    func mailDeleteDraft(_ ref: MailItemRef) async throws {
        _ = try await ewsCall(action: "DeleteItem", soap: OWAMailPayloads.deleteItemSOAP(ref), mayRepeat: true, note: "")
    }

    /// One EWS SOAP call on the shared NTLM session.
    ///
    /// - Parameter mayRepeat: whether a request dropped by the connection may be sent again.
    ///   Only for requests whose repetition is harmless; a 401/440 is always retried once, as the
    ///   server answered it without acting on it.
    /// - Parameter area: what the call is for in the logs ("Mail", "Meeting").
    func ewsCall(action: String, soap: String, mayRepeat: Bool, note: String, area: String = "Mail", attempt: Int = 0) async throws -> String {
        // Pictures make a request megabytes long: time to upload them at a slow ~50 KB/s.
        var request = URLRequest(url: try url("/EWS/Exchange.asmx"), timeoutInterval: max(30, Double(soap.utf8.count) / 50_000))
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("\"http://schemas.microsoft.com/exchange/services/2006/messages/\(action)\"", forHTTPHeaderField: "SOAPAction")
        addCommonHeaders(&request)
        request.httpBody = Data(soap.utf8)
        log.info("EWS \(area, privacy: .public) \(action, privacy: .public) \(note, privacy: .public) bytes=\(soap.utf8.count, privacy: .public)")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = mayRepeat ? try await sessionDataAllowingStaleReconnect(for: request) : try await fetchData(request)
        } catch let urlErr as URLError where mayRepeat && urlErr.code == .networkConnectionLost && attempt < 1 {
            DiagnosticLog.event("\(area) \(action) URLError \(urlErr.code.rawValue), re-authenticating")
            try await authenticate()
            return try await ewsCall(action: action, soap: soap, mayRepeat: mayRepeat, note: note, area: area, attempt: attempt + 1)
        } catch let urlErr as URLError where !mayRepeat && Self.mayHaveReachedServer(urlErr) {
            DiagnosticLog.event("\(area) \(action) URLError \(urlErr.code.rawValue): outcome unknown, not repeated")
            throw MailError.sendUncertain
        }
        guard let http = response as? HTTPURLResponse else { throw OWAError.invalidResponse }
        if OWAError.isSessionStaleStatus(http.statusCode) {
            guard attempt < 1 else { throw OWAError.httpError(http.statusCode, "EWS \(area) \(action) auth retry exhausted") }
            try await authenticate()
            return try await ewsCall(action: action, soap: soap, mayRepeat: mayRepeat, note: note, area: area, attempt: attempt + 1)
        }
        let body = String(data: data, encoding: .utf8) ?? ""
        guard (200..<300).contains(http.statusCode) else {
            log.error("EWS \(area, privacy: .public) \(action, privacy: .public) HTTP \(http.statusCode, privacy: .public)")
            throw OWAError.httpError(http.statusCode, String(body.prefix(600)))
        }
        let code = Self.extractEWSResponseCode(from: body)
        log.info("EWS \(area, privacy: .public) \(action, privacy: .public) responseCode=\(code ?? "nil", privacy: .public)")
        DiagnosticLog.event("\(area) \(action) code=\(code ?? "nil")")
        guard code == "NoError" else { throw OWAError.ewsError(code ?? "UnknownError") }
        return body
    }

    /// A failure after which the request may have been processed: the bytes went out and the
    /// answer did not come back. Failures before any connection (no network, DNS, TLS refusal)
    /// mean the server never saw it.
    static func mayHaveReachedServer(_ error: URLError) -> Bool {
        switch error.code {
        case .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
             .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected,
             .appTransportSecurityRequiresSecureConnection, .userAuthenticationRequired:
            return false
        default:
            return true
        }
    }
}
