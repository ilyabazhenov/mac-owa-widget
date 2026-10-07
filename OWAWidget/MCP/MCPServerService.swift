import Foundation
import OWAWidgetMCPShared
import UserNotifications

/// Owns the MCP socket for the app's lifetime and publishes its state to the settings tab.
///
/// The listener runs whenever the app runs, even with the feature off: a disabled server answers
/// every tool call with "turned off in Settings", which is the only way a user looking at an MCP
/// client can learn where the switch is. It never returns calendar data while disabled.
@MainActor
final class MCPServerService: ObservableObject {
    static let shared = MCPServerService()
    static let enabledDefaultsKey = "mcpServerEnabled"
    /// Off by default and separate from the main switch: reading the calendar and sending
    /// invitations on the user's behalf are different decisions.
    static let createMeetingsDefaultsKey = "mcpCreateMeetingsEnabled"
    /// On by default: a client the user has not seen before reads nothing until they allow it.
    static let askNewClientsDefaultsKey = "mcpAskNewClients"
    /// After an unanswered question the client gets "waiting for the user" without a new panel
    /// for this long: a widget that polls every minute must not reopen it every minute.
    static let unansweredQuestionCooldown: TimeInterval = 10 * 60
    static let journalLimit = 50

    enum Status: Equatable {
        case stopped
        case listening
        case unavailable(String)
    }

    struct JournalEntry: Identifiable, Equatable {
        let id = UUID()
        let date: Date
        let tool: String
        let client: String?
        let isError: Bool
    }

    /// An open connection. `identity` is `nil` while the server is still looking it up.
    struct Client: Identifiable, Equatable {
        let id: UUID
        let connectedAt: Date
        var identity: MCPClientIdentity?
        var declaredName: String?
        var hasSentMessage = false
        var isRecorded = false
    }

    nonisolated static let notificationIdentifierPrefix = "owawidget-mcp-client."
    /// Client names are the client's own words; long ones are cut before they reach the UI.
    static let declaredNameLimit = 80

    @Published private(set) var status: Status = .stopped
    @Published private(set) var clients: [Client] = []
    /// Every client that has talked to the server while it was on, newest first. Persisted.
    @Published private(set) var knownClients: [MCPKnownClient] = []
    /// In memory only: who called which tool, never arguments or results.
    @Published private(set) var journal: [JournalEntry] = []
    @Published var isEnabled: Bool = UserDefaults.standard.bool(forKey: MCPServerService.enabledDefaultsKey) {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledDefaultsKey)
            MCPDebugLog.log("enabled=\(isEnabled)")
            if isEnabled {
                // Clients that connected while the switch was off start reading only now.
                for client in clients where client.hasSentMessage && !client.isRecorded {
                    recordKnownClient(client.id)
                }
            }
        }
    }
    @Published var askNewClients: Bool = UserDefaults.standard.object(forKey: MCPServerService.askNewClientsDefaultsKey) as? Bool ?? true {
        didSet {
            guard askNewClients != oldValue else { return }
            UserDefaults.standard.set(askNewClients, forKey: Self.askNewClientsDefaultsKey)
            MCPDebugLog.log("askNewClients=\(askNewClients)")
        }
    }
    @Published var canCreateMeetings: Bool = UserDefaults.standard.bool(forKey: MCPServerService.createMeetingsDefaultsKey) {
        didSet {
            guard canCreateMeetings != oldValue else { return }
            UserDefaults.standard.set(canCreateMeetings, forKey: Self.createMeetingsDefaultsKey)
            MCPDebugLog.log("createMeetings=\(canCreateMeetings)")
        }
    }

    private(set) var socketPath: String = ""
    private var listener: MCPSocketListener?
    private var watchdog: Timer?
    private var toolbox: MCPToolbox?
    private var handler: MCPProtocolHandler?
    private var verifier: MCPPeerVerifier?
    private let inspector = MCPSystemProcessInspector()
    private var approval: MCPClientApprovalController?
    private var unansweredUntil: [String: Date] = [:]

    private init() {}

    /// Starts listening. Called from the menu-bar label's `onAppear`, which runs at launch;
    /// later calls are no-ops.
    func start(calendarService: CalendarService) {
        guard toolbox == nil else { return }
        MCPDebugLog.reset()

        let calendarTools = MCPCalendarTools(
            calendarService: calendarService,
            isEnabled: { UserDefaults.standard.bool(forKey: MCPServerService.enabledDefaultsKey) },
            canCreateMeetings: { UserDefaults.standard.bool(forKey: MCPServerService.createMeetingsDefaultsKey) }
        )
        toolbox = MCPToolbox(calendarTools: calendarTools) { tool, client, isError in
            MCPServerService.shared.record(tool: tool, client: client, isError: isError)
        }
        let info = Bundle.main.infoDictionary
        handler = MCPProtocolHandler(
            serverName: "owa-widget",
            serverTitle: "OWA Widget",
            serverVersion: (info?["CFBundleShortVersionString"] as? String) ?? "dev",
            instructions: MCPToolRegistry.instructions,
            tools: MCPToolRegistry.tools
        )

        verifier = MCPPeerVerifier.forCurrentApp(bridgePath: bridgePath)
        let approval = MCPClientApprovalController()
        approval.onDecision = { key, allowed in
            MCPServerService.shared.setAccess(allowed ? .allowed : .denied, forKey: key)
        }
        approval.onTimeout = { key in
            MCPServerService.shared.unansweredUntil[key] = Date().addingTimeInterval(MCPServerService.unansweredQuestionCooldown)
        }
        self.approval = approval
        knownClients = MCPKnownClientList.sorted(MCPKnownClientsStore.shared.load() ?? [])

        let bundleID = Bundle.main.bundleIdentifier ?? "com.owawidget.MacOwaWidget"
        socketPath = MCPSocketPath.socketURL(
            bundleIdentifier: bundleID,
            homeDirectory: MCPSocketPath.userHomeDirectory()
        ).path
        startListener()

        // Cache cleaners or a second copy of the app can delete or replace the socket file;
        // without this the server would go silently unreachable until the next launch.
        watchdog = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in MCPServerService.shared.checkSocket() }
        }
    }

    /// Path of the bridge binary inside this bundle, for the configuration snippets.
    var bridgePath: String {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/owawidget-mcp", isDirectory: false)
            .path
    }

    var isBridgeInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: bridgePath)
    }

    // MARK: - Listener

    private func startListener() {
        guard let toolbox, let handler else { return }
        guard MCPSocketPath.fitsSocketAddress(URL(fileURLWithPath: socketPath)) else {
            status = .unavailable("Socket path is too long: \(socketPath)")
            MCPDebugLog.log("socket path too long: \(socketPath.utf8.count) bytes")
            return
        }
        let listener = MCPSocketListener(path: socketPath) { channel in
            Task { @MainActor in
                MCPServerService.shared.accept(channel, toolbox: toolbox, handler: handler)
            }
        }
        do {
            try listener.start()
            self.listener = listener
            status = .listening
            MCPDebugLog.log("listening at \(socketPath)")
        } catch {
            status = .unavailable(error.localizedDescription)
            MCPDebugLog.log("listen failed: \(error.localizedDescription)")
        }
    }

    /// Rebinds a running listener whose socket file vanished or was replaced. A listener that
    /// never started (path too long, another copy serving) stays down: retrying every minute
    /// would only repeat the same failure in the log.
    private func checkSocket() {
        guard let listener, !listener.isSocketFileIntact else { return }
        MCPDebugLog.log("socket file missing or replaced, rebinding")
        listener.stop()
        self.listener = nil
        startListener()
    }

    private func accept(_ channel: MCPSocketChannel, toolbox: MCPToolbox, handler: MCPProtocolHandler) {
        let clientID = UUID()
        clients.append(Client(id: clientID, connectedAt: Date()))
        MCPDebugLog.log("client connected (\(clients.count) active)")
        // Read now: the kernel keeps the peer's credentials, but its pid means something only
        // while the process lives.
        let peer = channel.peerCredentials()
        let verifier = verifier ?? MCPPeerVerifier(requirementText: nil, bridgePath: bridgePath)
        let inspector = inspector
        // Signature checks and process lookups take milliseconds; keep them off the main actor.
        // The client's lines wait in the socket meanwhile.
        Task.detached {
            let identity = Self.identify(peer, verifier: verifier, inspector: inspector)
            await MainActor.run {
                MCPServerService.shared.serve(channel, clientID: clientID, identity: identity, toolbox: toolbox, handler: handler)
            }
        }
    }

    nonisolated static func identify(
        _ peer: MCPPeerCredentials?,
        verifier: MCPPeerVerifier,
        inspector: any MCPProcessInspecting
    ) -> MCPClientIdentity {
        guard let peer else { return .unknown(kind: .direct, pid: 0) }
        let kind = verifier.kind(of: peer, executablePath: MCPSystemProcessInspector.executablePath(peer.pid))
        return MCPClientIdentifier.identify(peerPID: peer.pid, kind: kind, inspector: inspector)
    }

    private func serve(
        _ channel: MCPSocketChannel,
        clientID: UUID,
        identity: MCPClientIdentity,
        toolbox: MCPToolbox,
        handler: MCPProtocolHandler
    ) {
        if let index = clients.firstIndex(where: { $0.id == clientID }) {
            clients[index].identity = identity
        }
        MCPDebugLog.log("client identified: kind=\(identity.kind.rawValue) pid=\(identity.pid) name=\(identity.name) path=\(identity.executablePath) script=\(identity.script ?? "-")")
        let connection = MCPConnection(
            channel: channel,
            handler: handler,
            tools: MCPGatedToolbox(base: toolbox, clientID: clientID),
            clientLabel: identity.isResolved ? identity.name : nil
        ) { event in
            Task { @MainActor in MCPServerService.shared.handle(event, clientID: clientID) }
        }
        Task {
            await connection.run()
            await MainActor.run { MCPServerService.shared.disconnected(clientID) }
        }
    }

    private func handle(_ event: MCPConnectionEvent, clientID: UUID) {
        guard let index = clients.firstIndex(where: { $0.id == clientID }) else { return }
        switch event {
        case .firstMessage(let declaredName):
            clients[index].hasSentMessage = true
            clients[index].declaredName = declaredName.map { String($0.prefix(Self.declaredNameLimit)) }
            if isEnabled { recordKnownClient(clientID) }
        case .declaredName(let name):
            let name = String(name.prefix(Self.declaredNameLimit))
            clients[index].declaredName = name
            if clients[index].isRecorded, let key = clients[index].identity?.key {
                updateKnownClients(MCPKnownClientList.noteDeclaredName(name, forKey: key, in: knownClients))
            }
        case .bridgeHello(let hello):
            // Only for comparison in the log: the identity above never depends on it.
            let found = clients[index].identity
            MCPDebugLog.log("bridge hello claims parent pid=\(hello.parent_pid) path=\(hello.parent_path ?? "-"); server found kind=\(found?.kind.rawValue ?? "-") pid=\(found?.pid ?? 0)")
        }
    }

    private func recordKnownClient(_ clientID: UUID) {
        guard let index = clients.firstIndex(where: { $0.id == clientID }),
              !clients[index].isRecorded,
              let identity = clients[index].identity, identity.isResolved else { return }
        clients[index].isRecorded = true
        var (list, isNew) = MCPKnownClientList.record(
            identity,
            at: Date(),
            in: knownClients,
            newClientAccess: askNewClients ? .pending : .allowed
        )
        if let declared = clients[index].declaredName {
            list = MCPKnownClientList.noteDeclaredName(declared, forKey: identity.key, in: list)
        }
        updateKnownClients(list)
        if isNew {
            MCPDebugLog.log("new client: \(identity.key)")
        }
        let access = knownClients.first { $0.key == identity.key }?.access
        switch MCPClientAccessPolicy.verdict(for: access, askNewClients: askNewClients) {
        case .ask:
            // Up at once, so the answer is usually in before the client's first tool call.
            if let request = approvalRequest(clientID), !isCoolingDown(identity.key) {
                approval?.ask(request)
            }
        case .allow:
            // The question is off: the notification is all the user gets.
            if isNew { Self.notifyNewClient(identity) }
        case .deny:
            break
        }
    }

    // MARK: - Access

    /// `nil` when the client may call tools; otherwise the error text it gets instead.
    func authorize(_ clientID: UUID) async -> String? {
        // A disabled server answers every call itself; there is nothing to ask about.
        guard isEnabled else { return nil }
        guard let index = clients.firstIndex(where: { $0.id == clientID }) else { return nil }
        guard let identity = clients[index].identity, identity.isResolved else {
            return askNewClients ? Self.unidentifiedMessage : nil
        }
        if !clients[index].isRecorded { recordKnownClient(clientID) }
        let access = knownClients.first { $0.key == identity.key }?.access
        switch MCPClientAccessPolicy.verdict(for: access, askNewClients: askNewClients) {
        case .allow:
            return nil
        case .deny:
            return Self.deniedMessage
        case .ask:
            guard !isCoolingDown(identity.key), let approval, let request = approvalRequest(clientID) else {
                return Self.waitingMessage
            }
            switch await approval.decision(for: request) {
            case .allowed: return nil
            case .denied: return Self.deniedMessage
            case .timedOut, .cancelled: return Self.waitingMessage
            }
        }
    }

    /// Allow or deny from the client list; answers an open question about that client too.
    func setAccess(_ access: MCPClientAccess, forKey key: String) {
        MCPDebugLog.log("set access \(access.rawValue): \(key)")
        updateKnownClients(MCPKnownClientList.setAccess(access, forKey: key, in: knownClients))
        unansweredUntil[key] = nil
        if access != .pending {
            approval?.resolve(key: key, allowed: access == .allowed)
        }
    }

    private func isCoolingDown(_ key: String) -> Bool {
        guard let until = unansweredUntil[key] else { return false }
        if until > Date() { return true }
        unansweredUntil[key] = nil
        return false
    }

    private func approvalRequest(_ clientID: UUID) -> MCPClientApprovalRequest? {
        guard let client = clients.first(where: { $0.id == clientID }),
              let identity = client.identity, identity.isResolved else { return nil }
        return MCPClientApprovalRequest(
            key: identity.key,
            name: identity.name,
            executablePath: identity.executablePath,
            script: identity.script,
            kind: identity.kind,
            declaredName: client.declaredName,
            canCreateMeetings: canCreateMeetings
        )
    }

    static let deniedMessage = "The user has not allowed this client to use OWA Widget, so nothing was read. "
        + "They can change that in OWA Widget → Settings → AI (MCP) → Clients."
    static let waitingMessage = "OWA Widget is asking the user whether to allow this client and has no answer yet, "
        + "so nothing was read. Ask the user to answer the question in OWA Widget, or to allow the client in "
        + "Settings → AI (MCP) → Clients, then retry."
    static let unidentifiedMessage = "OWA Widget could not tell which program this connection belongs to, "
        + "so it cannot ask the user about it and nothing was read."

    private func updateKnownClients(_ list: [MCPKnownClient]) {
        guard list != knownClients else { return }
        knownClients = list
        _ = MCPKnownClientsStore.shared.save(list)
    }

    /// Removes a client from the list; its next connection notifies again.
    func forgetKnownClient(_ key: String) {
        MCPDebugLog.log("forget client: \(key)")
        updateKnownClients(knownClients.filter { $0.key != key })
        for index in clients.indices where clients[index].identity?.key == key {
            clients[index].isRecorded = false
        }
    }

    func isConnected(_ key: String) -> Bool {
        clients.contains { $0.identity?.key == key }
    }

    private static func notifyNewClient(_ identity: MCPClientIdentity) {
        let localization = LocalizationService()
        let content = UNMutableNotificationContent()
        content.title = localization.tr("mcp.clients.notification.title")
        let path = [identity.executablePath, identity.script].compactMap { $0 }.joined(separator: " ")
        content.body = localization.tr("mcp.clients.notification.body", identity.name, path)
        let request = UNNotificationRequest(
            identifier: notificationIdentifierPrefix + MCPShortHash.hex(identity.key, bytes: 8),
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    private func disconnected(_ id: UUID) {
        clients.removeAll { $0.id == id }
        MCPDebugLog.log("client disconnected (\(clients.count) active)")
    }

    private func record(tool: String, client: String?, isError: Bool) {
        MCPDebugLog.log("call \(tool) client=\(client ?? "-") error=\(isError)")
        journal.insert(JournalEntry(date: Date(), tool: tool, client: client, isError: isError), at: 0)
        if journal.count > Self.journalLimit {
            journal.removeLast(journal.count - Self.journalLimit)
        }
    }
}

/// The toolbox one connection sees: every tool call first asks `MCPServerService.authorize`
/// whether this client may read. `tools/list` and the handshake are not gated — they carry no
/// calendar data, and a client that fails to start because a question is open is worse.
struct MCPGatedToolbox: MCPToolProviding {
    let base: MCPToolbox
    let clientID: UUID

    var tools: [MCPToolDefinition] { base.tools }

    func callTool(name: String, arguments: [String: JSONValue], client: String?) async -> MCPToolResult {
        if let refusal = await MCPServerService.shared.authorize(clientID) {
            await base.recordCall(name, client, true)
            return .failure(refusal)
        }
        return await base.callTool(name: name, arguments: arguments, client: client)
    }
}
