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
            guard let data = try? await mailServiceCall(action: "GetFolder", payload: payload),
                  let json = try? OWAMailParsers.json(data),
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

    func mailUpdate(_ refs: [MailItemRef], _ update: MailItemUpdate) async throws -> [MailItemRef] {
        guard !refs.isEmpty else { return [] }
        let data = try await mailServiceCall(action: "UpdateItem", payload: OWAMailPayloads.updateItems(refs, update: update, timeZoneID: windowsTimezoneID()))
        let updated = try OWAMailParsers.updatedRefs(data)
        return updated.count == refs.count ? updated : refs
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

    /// `CreateItem` through EWS, like `createCalendarEvent`: the same NTLM session, the same
    /// handling of a POST dropped on a fresh connection and of a stale session.
    func mailSend(_ outgoing: MailOutgoing, attempt: Int = 0) async throws -> MailItemRef? {
        let soap = OWAMailPayloads.createMessageSOAP(outgoing)
        let ewsURL = try url("/EWS/Exchange.asmx")
        var request = URLRequest(url: ewsURL, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("\"http://schemas.microsoft.com/exchange/services/2006/messages/CreateItem\"", forHTTPHeaderField: "SOAPAction")
        addCommonHeaders(&request)
        request.httpBody = Data(soap.utf8)
        log.info("EWS mail CreateItem kind=\(outgoing.kind.rawValue, privacy: .public) send=\(outgoing.send, privacy: .public) to=\(outgoing.to.count, privacy: .public) cc=\(outgoing.cc.count, privacy: .public) bytes=\(soap.utf8.count, privacy: .public)")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await sessionDataAllowingStaleReconnect(for: request)
        } catch let urlErr as URLError where urlErr.code == .networkConnectionLost && attempt < 1 {
            // A POST that is the first request on a fresh connection is dropped before NTLM: the
            // server never saw it, so resending cannot send the message twice.
            DiagnosticLog.event("Mail CreateItem URLError \(urlErr.code.rawValue), re-authenticating")
            try await authenticate()
            return try await mailSend(outgoing, attempt: attempt + 1)
        }
        guard let http = response as? HTTPURLResponse else { throw OWAError.invalidResponse }
        if OWAError.isSessionStaleStatus(http.statusCode) {
            guard attempt < 1 else { throw OWAError.httpError(http.statusCode, "EWS mail CreateItem auth retry exhausted") }
            try await authenticate()
            return try await mailSend(outgoing, attempt: attempt + 1)
        }
        let body = String(data: data, encoding: .utf8) ?? ""
        guard (200..<300).contains(http.statusCode) else {
            log.error("EWS mail CreateItem HTTP \(http.statusCode, privacy: .public)")
            throw OWAError.httpError(http.statusCode, String(body.prefix(600)))
        }
        let code = Self.extractEWSResponseCode(from: body)
        log.info("EWS mail CreateItem responseCode=\(code ?? "nil", privacy: .public)")
        DiagnosticLog.event("Mail CreateItem kind=\(outgoing.kind.rawValue) send=\(outgoing.send) code=\(code ?? "nil")")
        guard code == "NoError" else { throw OWAError.ewsError(code ?? "UnknownError") }
        return OWAMailParsers.createdItemRef(fromSOAP: body)
    }
}
