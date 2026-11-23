import Foundation
import OWAWidgetMCPShared

/// What a connection reports to `MCPServerService` besides tool calls.
enum MCPConnectionEvent: Sendable {
    /// The first MCP message arrived. A connection that never sends one (a second copy of the app
    /// probing whether the socket is alive) is not a client. Carries the name the client gave
    /// itself in that message, so the question panel can show it.
    case firstMessage(declaredName: String?)
    /// The client's name for itself changed after the first message. A claim, not an identity.
    case declaredName(String)
    /// The bridge's first line: who it says its parent is. A claim as well; logged for comparison.
    case bridgeHello(MCPBridgeHello)
}

/// One client connection: reads lines, runs them through `MCPProtocolHandler` in order, and runs
/// tool calls concurrently so a slow network tool does not hold up `tools/list`.
actor MCPConnection {
    private let channel: MCPSocketChannel
    private let handler: MCPProtocolHandler
    private let tools: any MCPToolProviding
    /// Who the server found on the other end (`MCPClientIdentifier`), for the journal and the
    /// confirmation window. Nothing the client sends can change it.
    private let clientLabel: String?
    private let onEvent: @Sendable (MCPConnectionEvent) -> Void

    private var session = MCPSessionState()
    private var isFirstLine = true
    private var sawMessage = false
    private var declaredName: String?
    /// Running tool calls by the canonical JSON of their request id. Removing an entry is what
    /// cancels a call's answer: `finish` only replies for ids still present.
    private var running: [String: Task<Void, Never>] = [:]
    /// Legacy `resources/subscribe` to the change resource.
    private var legacySubscribed = false
    /// Open `subscriptions/listen` requests, by the canonical JSON of their id.
    private var listens: [String: Listen] = [:]

    /// What one `subscriptions/listen` stream accepted.
    private struct Listen {
        let id: JSONValue
        let filter: MCPListenFilter
    }

    var hasSubscriptions: Bool { legacySubscribed || !listens.isEmpty }

    init(
        channel: MCPSocketChannel,
        handler: MCPProtocolHandler,
        tools: any MCPToolProviding,
        clientLabel: String?,
        onEvent: @escaping @Sendable (MCPConnectionEvent) -> Void
    ) {
        self.channel = channel
        self.handler = handler
        self.tools = tools
        self.clientLabel = clientLabel?.isEmpty == false ? clientLabel : nil
        self.onEvent = onEvent
    }

    func run() async {
        for await line in channel.lines() {
            receive(line)
        }
        for task in running.values { task.cancel() }
        running.removeAll()
        channel.close()
    }

    func receive(_ line: Data) {
        if isFirstLine {
            isFirstLine = false
            if let hello = MCPBridgeHello.decode(line) {
                onEvent(.bridgeHello(hello))
                return
            }
        }
        let message = JSONLine.decode(line)
        let name = message.flatMap(Self.clientName(in:))
        if !sawMessage {
            sawMessage = true
            declaredName = name
            onEvent(.firstMessage(declaredName: name))
        } else if let name, name != declaredName {
            declaredName = name
            onEvent(.declaredName(name))
        }

        guard let message else {
            channel.send(JSONLine.encode(JSONRPC.error(id: .null, code: JSONRPCErrorCode.parseError, message: "Parse error")))
            return
        }

        switch handler.handle(message, session: &session) {
        case .none:
            break
        case .reply(let response):
            channel.send(JSONLine.encode(response))
        case .cancel(let requestID):
            let key = JSONLine.encodeString(requestID)
            running.removeValue(forKey: key)?.cancel()
            // A cancelled listen gets no answer and no further message.
            listens.removeValue(forKey: key)
        case .subscribe(let id):
            let tools = self.tools
            Task { [weak self] in
                let refusal = await tools.authorizeSubscription()
                await self?.subscribed(id: id, refusal: refusal)
            }
        case .unsubscribe(let id):
            legacySubscribed = false
            channel.send(JSONLine.encode(handler.subscribeResponse(id: id)))
        case .listen(let id, let filter):
            let key = JSONLine.encodeString(id)
            let tools = self.tools
            // Held like a running call, so a cancel that races the check still wins.
            running[key] = Task { [weak self] in
                let refusal = await tools.authorizeSubscription()
                guard !Task.isCancelled else { return }
                await self?.listening(id: id, key: key, filter: filter, refusal: refusal)
            }
        case .callTool(let id, let name, let arguments, let modern):
            let key = JSONLine.encodeString(id)
            let tools = self.tools
            let handler = self.handler
            let client = clientLabel
            running[key] = Task { [weak self] in
                let result = await tools.callTool(name: name, arguments: arguments, client: client)
                guard !Task.isCancelled else { return }
                await self?.finish(key: key, response: handler.toolCallResponse(id: id, result: result, modern: modern))
            }
        }
    }

    private func subscribed(id: JSONValue, refusal: String?) {
        if let refusal {
            channel.send(JSONLine.encode(JSONRPC.error(id: id, code: JSONRPCErrorCode.invalidRequest, message: refusal)))
            return
        }
        legacySubscribed = true
        channel.send(JSONLine.encode(handler.subscribeResponse(id: id)))
    }

    private func listening(id: JSONValue, key: String, filter: MCPListenFilter, refusal: String?) {
        guard running.removeValue(forKey: key) != nil else { return }
        if let refusal {
            channel.send(JSONLine.encode(handler.listenRefused(id: id, message: refusal)))
            return
        }
        listens[key] = Listen(id: id, filter: filter)
        channel.send(JSONLine.encode(handler.listenAcknowledgment(id: id, filter: filter)))
    }

    /// Something changed: one `notifications/resources/updated` per subscription. What changed
    /// the client reads with `get_changes`.
    func notifyChanged() {
        notify(resources: true, toolList: false)
    }

    /// `resources`: the change resource rings on every subscription to it. `toolList`:
    /// `notifications/tools/list_changed` — on a legacy session (the capability is in its
    /// `initialize` answer, no subscription needed) and on every `subscriptions/listen` stream
    /// that asked for `toolsListChanged`.
    func notify(resources: Bool, toolList: Bool) {
        if toolList, case .legacy = session.era {
            channel.send(JSONLine.encode(handler.toolsListChanged(subscriptionID: nil)))
        }
        if resources, legacySubscribed {
            channel.send(JSONLine.encode(handler.resourceUpdated(subscriptionID: nil)))
        }
        for listen in listens.values.sorted(by: { JSONLine.encodeString($0.id) < JSONLine.encodeString($1.id) }) {
            if toolList, listen.filter.toolsListChanged {
                channel.send(JSONLine.encode(handler.toolsListChanged(subscriptionID: listen.id)))
            }
            if resources, listen.filter.changes {
                channel.send(JSONLine.encode(handler.resourceUpdated(subscriptionID: listen.id)))
            }
        }
    }

    private func finish(key: String, response: JSONValue) {
        // Gone means cancelled: the spec forbids any further message for a cancelled request.
        guard running.removeValue(forKey: key) != nil else { return }
        channel.send(JSONLine.encode(response))
    }

    // MARK: - Labels

    static func clientName(in message: JSONValue) -> String? {
        let params = message["params"]
        let info = params?["clientInfo"] ?? params?["_meta"]?["io.modelcontextprotocol/clientInfo"]
        let title = info?["title"]?.stringValue
        let name = info?["name"]?.stringValue
        return (title?.isEmpty == false ? title : name).flatMap { $0.isEmpty ? nil : $0 }
    }
}
