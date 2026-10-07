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
