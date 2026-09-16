import Foundation
import os.log

/// Stops redirects that would otherwise forward a manually attached Basic credential to an
/// unconfigured host. Redirects within the configured host retain the original request.
final class EASRedirectDelegate: NSObject, URLSessionTaskDelegate {
    private let configuredHost: String

    init(configuredHost: String) {
        self.configuredHost = configuredHost.lowercased()
    }

    func permitsRedirection(to url: URL?) -> Bool {
        url?.host?.lowercased() == configuredHost
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard permitsRedirection(to: request.url) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

/// Exchange ActiveSync transport.
///
/// Speaks exactly one endpoint — `POST /Microsoft-Server-ActiveSync` — which is why this
/// works where the OWA client does not: that single path is published to the internet,
/// while `/owa/service.svc`, `/EWS/Exchange.asmx` and autodiscover are not.
///
/// Authentication is Basic. That has one sharp consequence, handled below: the password is
/// sent on every request, so a wrong password must stop the client dead rather than being
/// retried into an Active Directory lockout.
actor EASClient {

    struct Configuration: Sendable {
        var host: String
        /// `DOMAIN\user`, the same form the OWA accounts already store.
        var username: String
        var password: String
        var deviceId: String
        var device: EASDeviceProfile
    }

    private static let protocolVersion = "14.1"
    private static let debugLogName = "easclient.log"

    private let config: Configuration
    private let session: URLSession
    private let log = Logger(subsystem: "com.owawidget", category: "EASClient")

    private var policyKey = "0"

    /// Latched by the first 401. Every later request fails without touching the network.
    ///
    /// This is the inner half of the lockout guard. One `fetchEvents` is two to four
    /// requests, and each would otherwise present the same rejected password again.
    private var credentialRejected = false

    init(_ config: Configuration) {
        self.config = config

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 120
        // Nothing here needs cookies; Basic goes out on every request.
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false

        // No custom server-trust handling: the system trust store
        // is the whole policy. The OWA client carries a trust-on-first-use escape hatch for
        // internal-CA certificates, but that is a deliberate relaxation of TLS validation, and
        // adding a second, never-exercised copy of it would be worse than not having one — a
        // path that looks handled and has never run. If a deployment ever presents a
        // certificate the system rejects, it surfaces here as a plain TLS error, which is both
        // honest and the right moment to add the prompt back.
        self.session = URLSession(
            configuration: configuration,
            delegate: EASRedirectDelegate(configuredHost: config.host),
            delegateQueue: nil
        )
    }

    // MARK: Logging

    private func debug(_ message: String) {
        #if DEBUG
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        DebugLogLocation.append("[\(formatter.string(from: Date()))] \(message)\n", to: Self.debugLogName)
        #endif
    }

    // MARK: Request building

    private var authorizationHeader: String {
        "Basic " + Data("\(config.username):\(config.password)".utf8).base64EncodedString()
    }

    private func endpoint(command: String?) throws -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = config.host
        components.path = "/Microsoft-Server-ActiveSync"
        if let command {
            components.queryItems = [
                URLQueryItem(name: "Cmd", value: command),
                URLQueryItem(name: "User", value: config.username),
                URLQueryItem(name: "DeviceId", value: config.deviceId),
                URLQueryItem(name: "DeviceType", value: config.device.deviceType),
            ]
        }
        guard let url = components.url else {
            throw EASError.protocolError("could not build a URL for host \(config.host)")
        }
        return url
    }

    private func makeRequest(url: URL, method: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        request.setValue(Self.protocolVersion, forHTTPHeaderField: "MS-ASProtocolVersion")
        request.setValue(config.device.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(policyKey, forHTTPHeaderField: "X-MS-PolicyKey")
        return request
    }

    // MARK: Sending

    /// Sends a WBXML command.
    ///
    /// `allowProvisionRetry` exists for one case only: a 449 means the server wants the
    /// device provisioned first, so we provision and replay once. It is deliberately not
    /// reachable from the 401 path.
    @discardableResult
    private func send(
        command: String,
        body: Data,
        allowProvisionRetry: Bool = true
    ) async throws -> [WBNode] {
        guard !credentialRejected else {
            debug("→ \(command): skipped, credentials already rejected")
            throw EASError.authenticationRejected
        }

        var request = makeRequest(url: try endpoint(command: command), method: "POST")
        request.setValue("application/vnd.ms-sync.wbxml", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw EASError.protocolError("no HTTP response for \(command)")
        }
        debug("→ \(command): HTTP \(http.statusCode), \(data.count) bytes")
        // Plaintext because this is the only log the user can read: macOS does not persist
        // unified-log `.info` entries to disk. Neither command, response code, nor byte size
        // contains personal data.
        DiagnosticLog.event("EAS \(command) http=\(http.statusCode) bytes=\(data.count)")

        switch http.statusCode {
        case 200:
            break

        case 401:
            // Basic authentication: a 401 is a rejection, not a challenge. Latch and stop.
            credentialRejected = true
            log.error("EAS \(command, privacy: .public) rejected credentials; client latched")
            throw EASError.authenticationRejected

        case 403:
            credentialRejected = true
            log.error("EAS \(command, privacy: .public) forbidden; client latched")
            throw EASError.forbidden("ActiveSync may be disabled for this mailbox.")

        case 449:
            guard allowProvisionRetry else {
                throw EASError.protocolError("the server asked for provisioning twice in a row")
            }
            debug("   449: provisioning required")
            try await provision()
            return try await send(command: command, body: body, allowProvisionRetry: false)

        case 451:
            let location = http.value(forHTTPHeaderField: "X-MS-Location") ?? "(unspecified)"
            throw EASError.http(451, "The server redirected to another node: \(location)")

        default:
            throw EASError.http(http.statusCode, Self.describeBody(data))
        }

        guard !data.isEmpty else { return [] }
        let tree = try WBXMLReader.parse(data)

        // The token names go to the unified log, where they can actually be read; the tree
        // itself stays in the encrypted trace because it carries subjects and addresses.
        // An unmapped token is a field arriving and being dropped, which is otherwise invisible.
        let unmapped = tree.unmappedTokens
        if !unmapped.isEmpty {
            // A token name is a protocol identifier such as `p10_0x16`, not content. This is
            // the complete code-page validation procedure: an unmapped token means a field
            // arrived and was discarded, and no other component reports that fact.
            let names = unmapped.sorted().joined(separator: ", ")
            log.notice("EAS \(command, privacy: .public) carried unmapped tokens: \(names, privacy: .public)")
            DiagnosticLog.event("EAS \(command) unmapped tokens: \(names)")
        }

        #if DEBUG
        debug("   response tree:\n\(tree.dumped)")
        #endif
        return tree
    }

    /// Reduces a response body to a shape, never its content: these strings are logged and
    /// shown in the UI, and an Exchange error body can carry mailbox data.
    private static func describeBody(_ data: Data) -> String {
        guard !data.isEmpty else { return "empty response" }
        return "\(data.count) bytes"
    }

    // MARK: OPTIONS

    /// Cheapest possible reachability and credential check: one request, no body, no state.
    func capabilities() async throws -> EASServerCapabilities {
        guard !credentialRejected else { throw EASError.authenticationRejected }

        let request = makeRequest(url: try endpoint(command: nil), method: "OPTIONS")
        let (_, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw EASError.protocolError("no HTTP response for OPTIONS")
        }
        debug("→ OPTIONS: HTTP \(http.statusCode)")

        switch http.statusCode {
        case 200:
            return EASServerCapabilities(
                protocolVersions: http.value(forHTTPHeaderField: "MS-ASProtocolVersions") ?? "",
                commands: http.value(forHTTPHeaderField: "MS-ASProtocolCommands") ?? "",
                server: http.value(forHTTPHeaderField: "Server") ?? ""
            )
        case 401:
            credentialRejected = true
            throw EASError.authenticationRejected
        case 403:
            credentialRejected = true
            throw EASError.forbidden("ActiveSync may be disabled for this mailbox.")
        default:
            throw EASError.http(http.statusCode, "OPTIONS failed")
        }
    }

    // MARK: Provision

    /// Two-phase policy negotiation: download the policy for a temporary key, acknowledge it,
    /// receive the key every later command must carry.
    ///
    /// The `DeviceInformation` block is not optional. Exchange 2010 and later answer
    /// `Status=165` (DeviceInformationRequired) without it, and it must precede `Policies`.
    func provision() async throws {
        let device = config.device

        let first = WBXMLWriter()
        first.node(PR.provision) {
            first.node(ST.deviceInformation) {
                first.node(ST.set) {
                    first.leaf(ST.model, device.model)
                    first.leaf(ST.friendlyName, device.friendlyName)
                    first.leaf(ST.os, device.osVersion)
                    first.leaf(ST.osLanguage, "en-us")
                    first.leaf(ST.userAgent, device.userAgent)
                }
            }
            first.node(PR.policies) {
                first.node(PR.policy) {
                    first.leaf(PR.policyType, "MS-EAS-Provisioning-WBXML")
                }
            }
        }

        let downloaded = try await send(command: "Provision", body: first.data, allowProvisionRetry: false)

        if let status = downloaded.first(ST.deviceInformation)?.value(ST.status) {
            debug("   DeviceInformation accepted, Status=\(status)")
        }
        if let status = downloaded.first(PR.provision)?.value(PR.status), status != "1" {
            throw EASError.commandStatus(command: "Provision", status: status)
        }
        guard let temporaryKey = downloaded.first(PR.policyKey)?.text, !temporaryKey.isEmpty else {
            throw EASError.protocolError("Provision returned no PolicyKey")
        }
        debug("   temporary PolicyKey \(temporaryKey)")

        policyKey = temporaryKey

        let acknowledgement = WBXMLWriter()
        acknowledgement.node(PR.provision) {
            acknowledgement.node(PR.policies) {
                acknowledgement.node(PR.policy) {
                    acknowledgement.leaf(PR.policyType, "MS-EAS-Provisioning-WBXML")
                    acknowledgement.leaf(PR.policyKey, temporaryKey)
                    acknowledgement.leaf(PR.status, "1")      // the policy is accepted
                }
            }
        }

        let confirmed = try await send(command: "Provision", body: acknowledgement.data, allowProvisionRetry: false)
        guard let finalKey = confirmed.first(PR.policyKey)?.text, !finalKey.isEmpty else {
            throw EASError.protocolError("the policy acknowledgement returned no PolicyKey")
        }
        policyKey = finalKey
        debug("   policy accepted, PolicyKey \(finalKey)")
    }

    // MARK: FolderSync

    func folders() async throws -> [EASFolder] {
        let writer = WBXMLWriter()
        writer.node(FH.folderSync) { writer.leaf(FH.syncKey, "0") }

        let response = try await send(command: "FolderSync", body: writer.data)
        guard let root = response.first(FH.folderSync) else {
            throw EASError.protocolError("FolderSync returned an unexpected document")
        }
        if let status = root.value(FH.status), status != "1" {
            throw EASError.commandStatus(command: "FolderSync", status: status)
        }

        let folders = (root.child(FH.changes)?.all(FH.add) ?? []).compactMap { node -> EASFolder? in
            guard let id = node.value(FH.serverId),
                  let name = node.value(FH.displayName),
                  let type = node.value(FH.type).flatMap(Int.init)
            else { return nil }
            return EASFolder(id: id, displayName: name, type: type)
        }
        debug("   \(folders.count) folders, \(folders.filter(\.isCalendar).count) of them calendars")
        return folders
    }

    /// The mailbox's own calendar, preferred over any user-created one.
    func defaultCalendarFolder() async throws -> EASFolder {
        let all = try await folders()
        if let primary = all.first(where: \.isDefaultCalendar) { return primary }
        if let any = all.first(where: \.isCalendar) { return any }
        debug("   no calendar folder among: " + all.map { "\($0.displayName)(\($0.type))" }.joined(separator: ", "))
        throw EASError.calendarFolderNotFound
    }

    // MARK: Sync

    /// Synchronises a collection.
    ///
    /// The first call of a chain must pass `syncKey: "0"`. That round never carries data — it
    /// only establishes a key — which is why the caller has to run a second one.
    ///
    /// `Status=3` means the server no longer recognises the key; the caller must restart from
    /// `"0"` and discard its local copy, because what arrives afterwards is a delta against a
    /// baseline it no longer shares.
    func sync(
        collectionId: String,
        syncKey: String,
        windowSize: Int = 100,
        filterType: Int = 0,
        bodyTruncationSize: Int = 1024
    ) async throws -> EASSyncResult {
        let isPriming = (syncKey == "0")

        let writer = WBXMLWriter()
        writer.node(AS.sync) {
            writer.node(AS.collections) {
                writer.node(AS.collection) {
                    // Element order follows the 14.1 schema; Exchange rejects a reordered body.
                    writer.leaf(AS.syncKey, syncKey)
                    writer.leaf(AS.collectionId, collectionId)
                    if !isPriming {
                        writer.leaf(AS.deletesAsMoves, "1")
                        writer.leaf(AS.getChanges, "1")
                        writer.leaf(AS.windowSize, String(windowSize))
                        writer.node(AS.options) {
                            writer.leaf(AS.filterType, String(filterType))
                            writer.node(ASB.bodyPreference) {
                                writer.leaf(ASB.type, "1")          // plain text
                                writer.leaf(ASB.truncationSize, String(bodyTruncationSize))
                            }
                        }
                    }
                }
            }
        }

        let response = try await send(command: "Sync", body: writer.data)

        // An empty body is Exchange's way of saying "nothing changed since that key".
        guard let collection = response.first(AS.collection) else {
            debug("   Sync: empty response, treating as no changes")
            return EASSyncResult(syncKey: syncKey, moreAvailable: false, upserted: [], deletedIds: [])
        }

        if let status = collection.value(AS.status), status != "1" {
            throw EASError.commandStatus(command: "Sync", status: status)
        }
        guard let newKey = collection.value(AS.syncKey), !newKey.isEmpty else {
            throw EASError.protocolError("Sync returned no SyncKey")
        }

        let commands = collection.child(AS.commands)
        let upserted = ((commands?.all(AS.add) ?? []) + (commands?.all(AS.change) ?? []))
            .compactMap { node -> EASCalendarItem? in
                guard let serverId = node.value(AS.serverId),
                      let data = node.child(AS.applicationData)
                else { return nil }
                return EASCalendarItem(serverId: serverId, applicationData: data)
            }
        let deleted = (commands?.all(AS.delete) ?? []).compactMap { $0.value(AS.serverId) }

        let more = collection.child(AS.moreAvailable) != nil
        debug("   Sync: key \(newKey), +\(upserted.count) -\(deleted.count)\(more ? ", more available" : "")")

        return EASSyncResult(
            syncKey: newKey,
            moreAvailable: more,
            upserted: upserted,
            deletedIds: deleted
        )
    }

    // MARK: MeetingResponse

    /// Answers a meeting invitation.
    ///
    /// Addressed by the calendar collection and the appointment's own `ServerId`, rather than by
    /// the invitation email — the widget never touches the mailbox. `instanceId` narrows the
    /// answer to one occurrence of a series; without it the whole series is answered.
    ///
    /// The tokens this builds come from an unverified table (page 8). A wrong one is accepted
    /// silently and changes nothing, so the check that matters is a round-trip: respond, then
    /// resynchronise and confirm `calendar:ResponseType` moved.
    func meetingResponse(
        collectionId: String,
        requestId: String,
        instanceId: String?,
        response: EASMeetingResponse
    ) async throws {
        let writer = WBXMLWriter()
        writer.node(MR.meetingResponse) {
            writer.node(MR.request) {
                writer.leaf(MR.userResponse, String(response.rawValue))
                writer.leaf(MR.collectionId, collectionId)
                writer.leaf(MR.requestId, requestId)
                if let instanceId {
                    writer.leaf(MR.instanceId, instanceId)
                }
            }
        }

        let tree = try await send(command: "MeetingResponse", body: writer.data)

        if let status = tree.first(MR.status)?.text, status != "1" {
            throw EASError.commandStatus(command: "MeetingResponse", status: status)
        }
        // A reply the server did not act on must not look like success. Without a Result the
        // request was understood as something else — the exact failure a wrong token produces.
        guard tree.first(MR.result) != nil else {
            throw EASError.protocolError("MeetingResponse returned no Result element")
        }
        debug("   MeetingResponse accepted for \(requestId)")
    }

    // MARK: Fetch

    /// Pulls one item in full, for a body the windowed sync truncated.
    ///
    /// Uses `Sync` with a `Fetch` command rather than `ItemOperations`: it needs only page 0 and
    /// page 17 tokens, both of which round-trip against this server today, where `ItemOperations`
    /// would add another unverified table for no gain.
    ///
    /// It does advance the synchronisation key, which is why it lives behind the session.
    func fetchItem(
        collectionId: String,
        syncKey: String,
        serverId: String,
        truncationSize: Int
    ) async throws -> (syncKey: String, item: EASCalendarItem?) {
        let writer = WBXMLWriter()
        writer.node(AS.sync) {
            writer.node(AS.collections) {
                writer.node(AS.collection) {
                    writer.leaf(AS.syncKey, syncKey)
                    writer.leaf(AS.collectionId, collectionId)
                    writer.node(AS.options) {
                        writer.node(ASB.bodyPreference) {
                            writer.leaf(ASB.type, "1")
                            writer.leaf(ASB.truncationSize, String(truncationSize))
                        }
                    }
                    writer.node(AS.commands) {
                        writer.node(AS.fetch) {
                            writer.leaf(AS.serverId, serverId)
                        }
                    }
                }
            }
        }

        let response = try await send(command: "Sync", body: writer.data)
        guard let collection = response.first(AS.collection) else {
            throw EASError.protocolError("Fetch returned no Collection")
        }
        if let status = collection.value(AS.status), status != "1" {
            throw EASError.commandStatus(command: "Sync", status: status)
        }
        let newKey = collection.value(AS.syncKey) ?? syncKey

        let fetched = collection.child(AS.responses)?.all(AS.fetch).first
        guard let fetched else {
            // The server accepted the request but did not return the item. This must be logged:
            // externally it looks like the meeting vanished, and diagnosis is impossible without it.
            DiagnosticLog.event("EAS fetch returned no item for \(serverId)")
            return (newKey, nil)
        }
        if let itemStatus = fetched.value(AS.status), itemStatus != "1" {
            DiagnosticLog.event("EAS fetch \(serverId) status=\(itemStatus)")
            return (newKey, nil)
        }
        guard let data = fetched.child(AS.applicationData) else {
            DiagnosticLog.event("EAS fetch \(serverId) had no ApplicationData")
            return (newKey, nil)
        }
        return (newKey, EASCalendarItem(serverId: serverId, applicationData: data))
    }

    // MARK: Creating a meeting

    /// Adds an appointment to the calendar collection.
    ///
    /// Invitations are the server's job: an item carrying an `Attendees` collection with
    /// `MeetingStatus = 1` makes Exchange send the meeting requests. There is no separate "send"
    /// step in ActiveSync, which also means a successful `Status` is the only confirmation the
    /// protocol offers — whether the invitations actually went out has to be checked in a
    /// mailbox.
    ///
    /// Elements go out in ascending token order, matching how the specification lists them:
    /// the calendar class is a sequence, and a reordered body risks being rejected.
    func createEvent(
        collectionId: String,
        syncKey: String,
        subject: String,
        agenda: String,
        location: String,
        start: Date,
        end: Date,
        requiredAttendees: [ResolvedAttendee],
        optionalAttendees: [ResolvedAttendee],
        timeZone: TimeZone
    ) async throws -> (syncKey: String, serverId: String?) {
        let body = Self.createEventBody(
            collectionId: collectionId,
            syncKey: syncKey,
            subject: subject,
            agenda: agenda,
            location: location,
            start: start,
            end: end,
            requiredAttendees: requiredAttendees,
            optionalAttendees: optionalAttendees,
            timeZone: timeZone
        )

        let response = try await send(command: "Sync", body: body)
        guard let collection = response.first(AS.collection) else {
            throw EASError.protocolError("the creation request returned no Collection")
        }
        if let status = collection.value(AS.status), status != "1" {
            throw EASError.commandStatus(command: "Sync", status: status)
        }

        let added = collection.child(AS.responses)?.all(AS.add).first
        // A per-item status of its own: the collection can succeed while the item is refused.
        if let itemStatus = added?.value(AS.status), itemStatus != "1" {
            throw EASError.commandStatus(command: "Sync Add", status: itemStatus)
        }

        let newKey = collection.value(AS.syncKey) ?? syncKey
        let serverId = added?.value(AS.serverId)
        debug("   created event \(serverId ?? "(no ServerId returned)")")
        return (newKey, serverId)
    }

    /// Builds the request body.
    ///
    /// Pure and static so the shape can be asserted without a server — which matters because
    /// every mistake available here is silent: a reordered sequence the server rejects, an
    /// attendee written as optional when they were required, a `MeetingStatus` of 0 that makes
    /// Exchange keep the meeting to itself and send no invitations at all.
    static func createEventBody(
        collectionId: String,
        syncKey: String,
        subject: String,
        agenda: String,
        location: String,
        start: Date,
        end: Date,
        requiredAttendees: [ResolvedAttendee],
        optionalAttendees: [ResolvedAttendee],
        timeZone: TimeZone,
        clientId: String = UUID().uuidString.replacingOccurrences(of: "-", with: ""),
        uid: String = UUID().uuidString.replacingOccurrences(of: "-", with: "").uppercased(),
        stamp: Date = Date()
    ) -> Data {
        let hasAttendees = !requiredAttendees.isEmpty || !optionalAttendees.isEmpty

        let writer = WBXMLWriter()
        writer.node(AS.sync) {
            writer.node(AS.collections) {
                writer.node(AS.collection) {
                    writer.leaf(AS.syncKey, syncKey)
                    writer.leaf(AS.collectionId, collectionId)
                    writer.node(AS.commands) {
                        writer.node(AS.add) {
                            writer.leaf(AS.clientId, String(clientId.prefix(32)))
                            writer.node(AS.applicationData) {
                                // Ascending token order, matching how the specification lists
                                // the calendar class: it is a sequence, and a reordered body
                                // risks rejection.
                                writer.leaf(CAL.timezone, EASWindowsTimeZone.blob(for: timeZone, at: start))
                                writer.leaf(CAL.allDayEvent, "0")

                                if hasAttendees {
                                    writer.node(CAL.attendees) {
                                        for attendee in requiredAttendees {
                                            writeAttendee(writer, attendee, type: 1)
                                        }
                                        for attendee in optionalAttendees {
                                            writeAttendee(writer, attendee, type: 2)
                                        }
                                    }
                                }

                                writer.leaf(CAL.busyStatus, "2")            // busy
                                writer.leaf(CAL.dtStamp, EASDate.format(stamp))
                                writer.leaf(CAL.endTime, EASDate.format(end))
                                if !location.isEmpty {
                                    writer.leaf(CAL.location, location)
                                }
                                // 1 = a meeting this user organises, which is what makes
                                // Exchange send the invitations. 0 would keep it private.
                                writer.leaf(CAL.meetingStatus, hasAttendees ? "1" : "0")
                                writer.leaf(CAL.sensitivity, "0")           // normal
                                writer.leaf(CAL.subject, subject)
                                writer.leaf(CAL.startTime, EASDate.format(start))
                                writer.leaf(CAL.uid, uid)

                                if !agenda.isEmpty {
                                    writer.node(ASB.body) {
                                        writer.leaf(ASB.type, "1")          // plain text
                                        writer.leaf(ASB.data, agenda)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        return writer.data
    }

    private static func writeAttendee(_ writer: WBXMLWriter, _ attendee: ResolvedAttendee, type: Int) {
        writer.node(CAL.attendee) {
            writer.leaf(CAL.email, attendee.email)
            writer.leaf(CAL.name, attendee.displayName.isEmpty ? attendee.email : attendee.displayName)
            writer.leaf(CAL.attendeeType, String(type))
        }
    }

    // MARK: Search — the global address list

    /// Directory search.
    ///
    /// Built from an unverified token table (page 15) with results on another (page 16). Unlike
    /// a wrong calendar token this one is visible: a mis-built request returns nothing at all.
    func searchGAL(query: String, limit: Int = 50) async throws -> [ResolvedAttendee] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let writer = WBXMLWriter()
        writer.node(SRCH.search) {
            writer.node(SRCH.store) {
                writer.leaf(SRCH.name, "GAL")
                writer.leaf(SRCH.query, trimmed)
                writer.node(SRCH.options) {
                    writer.leaf(SRCH.range, "0-\(max(0, limit - 1))")
                }
            }
        }

        let response = try await send(command: "Search", body: writer.data)
        if let status = response.first(SRCH.search)?.value(SRCH.status), status != "1" {
            // Status 2 here is "the store is not searchable", not a failure worth latching.
            debug("   Search returned Status=\(status)")
            return []
        }

        let results = response.first(SRCH.response)?.first(SRCH.store)?.all(SRCH.result) ?? []
        let people = results.compactMap { result -> ResolvedAttendee? in
            guard let properties = result.child(SRCH.properties) else { return nil }
            guard let email = properties.value(GAL.emailAddress)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty
            else { return nil }

            let name = properties.value(GAL.displayName)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let title = properties.value(GAL.title)?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            return ResolvedAttendee(
                displayName: name?.isEmpty == false ? name! : email,
                email: email,
                jobTitle: title?.isEmpty == false ? title : nil
            )
        }
        debug("   Search '\(trimmed)' → \(people.count) people")
        return people
    }

    // MARK: Settings — who the user is

    /// The mailbox's own SMTP address.
    ///
    /// Needed because the account login is `DOMAIN\user`, which is not an address, and the
    /// free/busy view has to know which row belongs to the organiser.
    func userSmtpAddress() async throws -> String? {
        let writer = WBXMLWriter()
        writer.node(ST.settings) {
            writer.node(ST.userInformation) {
                writer.open(ST.get)
                writer.close()
            }
        }

        let response = try await send(command: "Settings", body: writer.data)
        let address = response.first(ST.smtpAddress)?.text
            .trimmingCharacters(in: .whitespacesAndNewlines)
        debug("   Settings resolved SMTP address: \(address == nil ? "none" : "yes")")
        return address?.isEmpty == false ? address : nil
    }

    // MARK: ResolveRecipients — free/busy

    /// Merged free/busy for a set of mailboxes.
    ///
    /// The answer is a digit string, one character per 30 minutes: 0 free, 1 tentative, 2 busy,
    /// 3 out of office. That is the same shape the rest of the app already parses.
    ///
    /// Two traps, both silent. The timestamps must be in the extended format — the compact
    /// calendar one produces a reply with no availability at all. And the response is matched
    /// back to the request by address rather than by position, because a server is free to omit,
    /// merge or reorder recipients it could not resolve.
    func resolveAvailability(
        emails: [String],
        from start: Date,
        to end: Date
    ) async throws -> [String: String] {
        let addresses = emails
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !addresses.isEmpty else { return [:] }

        let writer = WBXMLWriter()
        writer.node(RR.resolveRecipients) {
            for address in addresses {
                writer.leaf(RR.to, address)
            }
            writer.node(RR.options) {
                writer.node(RR.availability) {
                    writer.leaf(RR.startTime, EASDate.formatExtended(start))
                    writer.leaf(RR.endTime, EASDate.formatExtended(end))
                }
            }
        }

        let response = try await send(command: "ResolveRecipients", body: writer.data)

        var byAddress: [String: String] = [:]
        for block in response.first(RR.resolveRecipients)?.all(RR.response) ?? [] {
            for recipient in block.all(RR.recipient) {
                guard let email = recipient.value(RR.emailAddress)?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty
                else { continue }
                guard let merged = recipient.child(RR.availability)?.value(RR.mergedFreeBusy),
                      !merged.isEmpty
                else { continue }
                byAddress[email.lowercased()] = merged
            }
        }
        debug("   ResolveRecipients: availability for \(byAddress.count) of \(addresses.count)")
        return byAddress
    }

    // MARK: Diagnostics

    /// Whether this client has latched a credential rejection, for callers deciding whether
    /// a retry is worth attempting at all.
    var hasRejectedCredentials: Bool { credentialRejected }
}
