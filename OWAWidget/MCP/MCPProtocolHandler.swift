import Foundation

/// One MCP tool as advertised in `tools/list`.
struct MCPToolDefinition: Sendable {
    let name: String
    let title: String
    let description: String
    let inputSchema: JSONValue
    /// `false` for the tools that change something: `create_meeting`, `cancel_meeting`,
    /// `prepare_mail`.
    var isReadOnly = true
    /// Removes something: `cancel_meeting`.
    var isDestructive = false

    var json: JSONValue {
        var annotations: [String: JSONValue] = [
            "title": .string(title),
            "readOnlyHint": .bool(isReadOnly),
            "openWorldHint": .bool(!isReadOnly),
        ]
        if !isReadOnly {
            annotations["destructiveHint"] = .bool(isDestructive)
            annotations["idempotentHint"] = false
        }
        return [
            "name": .string(name),
            "title": .string(title),
            "description": .string(description + MCPToolErrorCodes.descriptionSuffix(for: name)),
            "inputSchema": inputSchema,
            "annotations": .object(annotations),
        ]
    }
}

/// Outcome of one tool call. Failures are tool results (`isError: true`) rather than JSON-RPC
/// errors, so the model reads the message and can correct its arguments or tell the user. A
/// failure also carries a stable `error_code` (and `setting` for a setting that is off) in
/// `structuredContent`, for clients that show their user what to do.
struct MCPToolResult: Sendable, Equatable {
    let structured: [String: JSONValue]?
    let error: MCPToolError?
    /// Content blocks after the text repeat of `structured`: the bytes of an attachment
    /// (`get_mail_attachment`), as an `image` or an embedded `resource`. Empty for every other
    /// tool, whose `content` stays the one text block.
    var binaryContent: [JSONValue] = []

    var errorMessage: String? { error?.message }
    var errorCode: MCPErrorCode? { error?.code }

    static func success(_ structured: [String: JSONValue]) -> MCPToolResult {
        MCPToolResult(structured: structured, error: nil)
    }

    /// `structured` carries only what describes the bytes: they travel once, in `binary`.
    static func success(_ structured: [String: JSONValue], binary: [JSONValue]) -> MCPToolResult {
        MCPToolResult(structured: structured, error: nil, binaryContent: binary)
    }

    static func failure(_ error: MCPToolError) -> MCPToolResult {
        MCPToolResult(structured: nil, error: error)
    }

    static func failure(_ code: MCPErrorCode, _ message: String) -> MCPToolResult {
        .failure(MCPToolError(code, message))
    }

    var isError: Bool { error != nil }

    var json: JSONValue {
        if let error {
            var fields: [String: JSONValue] = [
                "error_code": .string(error.code.rawValue),
                "message": .string(error.message),
            ]
            if let setting = error.setting {
                fields["setting_id"] = .string(setting.rawValue)
                if let title = error.settingTitle { fields["setting"] = .string(title) }
            }
            return [
                "content": [["type": "text", "text": .string(error.message)]],
                "structuredContent": .object(fields),
                "isError": true,
            ]
        }
        let object = JSONValue.object(structured ?? [:])
        // The spec asks tools that return structured content to repeat it as text, for clients
        // that only read `content`. `structuredContent` stays an object for the legacy schemas.
        let text: JSONValue = ["type": "text", "text": .string(JSONLine.encodeString(object))]
        return [
            "content": .array([text] + binaryContent),
            "structuredContent": object,
            "isError": false,
        ]
    }
}

protocol MCPToolProviding: Sendable {
    var tools: [MCPToolDefinition] { get }
    func callTool(name: String, arguments: [String: JSONValue], client: String?) async -> MCPToolResult
    /// `nil` when the client may subscribe to the change resource; otherwise why not. Gated like
    /// a tool call: even "something changed" says when the user's mail or calendar moved.
    func authorizeSubscription() async -> String?
}

extension MCPToolProviding {
    func authorizeSubscription() async -> String? { nil }
}

/// Which MCP era a connection speaks. Decided by how the client opens: an `initialize` handshake
/// (2025-11-25 and earlier) or per-request `_meta` (2026-07-28).
enum MCPEra: Equatable, Sendable {
    case undetermined
    case legacy(version: String)
}

/// What a `subscriptions/listen` stream carries: the part of the client's filter this server
/// honours.
struct MCPListenFilter: Equatable, Sendable {
    /// `owawidget://changes` was in `resourceSubscriptions`.
    var changes: Bool
    /// `toolsListChanged: true`: the mail tools come and go with their switches.
    var toolsListChanged: Bool
}

struct MCPSessionState: Sendable {
    var era: MCPEra = .undetermined
}

enum MCPDispatch: Equatable, Sendable {
    case reply(JSONValue)
    case none
    case cancel(requestID: JSONValue)
    case callTool(id: JSONValue, name: String, arguments: [String: JSONValue], modern: Bool)
    /// Legacy `resources/subscribe` / `resources/unsubscribe` to the change resource; the
    /// connection answers once it knows whether the client may subscribe.
    case subscribe(id: JSONValue)
    case unsubscribe(id: JSONValue)
    /// Modern `subscriptions/listen` asking for the change resource, tool list changes or both.
    /// The request stays open: the connection acknowledges it and sends
    /// `notifications/resources/updated` and `notifications/tools/list_changed` on it.
    case listen(id: JSONValue, filter: MCPListenFilter)
}

/// The one resource: a doorbell for `get_changes`. Subscribing to it is how a client hears that
/// something changed; what changed it reads with the tool and its cursor.
enum MCPChangeResource {
    static let uri = "owawidget://changes"
    static let name = "changes"
    static let title = "Calendar and inbox changes"
    static let description = "Subscribe to hear when meetings or the inbox changed; read what changed with get_changes and your cursor. Reading this resource returns only that hint."
    /// How long a client may cache `resources/list` and `resources/read` (modern era).
    static let listTTLMilliseconds: Int64 = 3_600_000

    static var listing: JSONValue {
        ["uri": .string(uri), "name": .string(name), "title": .string(title), "description": .string(description), "mimeType": "application/json"]
    }

    static var contents: JSONValue {
        [[
            "uri": .string(uri),
            "mimeType": "application/json",
            "text": .string(JSONLine.encodeString(["hint": "Call get_changes with the cursor of your previous answer."])),
        ]]
    }
}

/// Pure JSON-RPC/MCP dispatch for both protocol eras. No I/O: `MCPConnection` feeds it one
/// message at a time and runs the tool calls it hands back.
struct MCPProtocolHandler: Sendable {
    static let modernVersion = "2026-07-28"
    /// Newest first: an unknown `initialize` version is answered with the first one.
    /// 2025-03-26 and older are not offered — that revision requires JSON-RPC batching.
    static let legacyVersions = ["2025-11-25", "2025-06-18"]
    static let metaVersionKey = "io.modelcontextprotocol/protocolVersion"
    static let metaCapabilitiesKey = "io.modelcontextprotocol/clientCapabilities"
    static let metaServerInfoKey = "io.modelcontextprotocol/serverInfo"
    /// The tool set changes only with the mail switches, and `notifications/tools/list_changed`
    /// says so: clients may cache it for an hour.
    static let toolsListTTLMilliseconds: Int64 = 3_600_000
    /// One resource and its updates: the push for `get_changes`. The tool list announces its
    /// changes (the mail tools come and go with their switches).
    static let capabilities: JSONValue = ["tools": ["listChanged": true], "resources": ["subscribe": true]]

    let serverName: String
    let serverTitle: String
    let serverVersion: String
    let instructions: String
    /// Read on every `tools/list` and `tools/call`: the mail tools come and go with their switch.
    let toolsProvider: @Sendable () -> [MCPToolDefinition]

    var tools: [MCPToolDefinition] { toolsProvider() }

    init(serverName: String, serverTitle: String, serverVersion: String, instructions: String, tools: [MCPToolDefinition]) {
        self.init(serverName: serverName, serverTitle: serverTitle, serverVersion: serverVersion, instructions: instructions, toolsProvider: { tools })
    }

    init(
        serverName: String,
        serverTitle: String,
        serverVersion: String,
        instructions: String,
        toolsProvider: @escaping @Sendable () -> [MCPToolDefinition]
    ) {
        self.serverName = serverName
        self.serverTitle = serverTitle
        self.serverVersion = serverVersion
        self.instructions = instructions
        self.toolsProvider = toolsProvider
    }

    private var serverInfo: JSONValue {
        ["name": .string(serverName), "title": .string(serverTitle), "version": .string(serverVersion)]
    }

    func handle(_ message: JSONValue, session: inout MCPSessionState) -> MCPDispatch {
        guard case .object(let object) = message else {
            return .reply(JSONRPC.error(id: .null, code: JSONRPCErrorCode.invalidRequest, message: "Invalid Request"))
        }
        let id = object["id"]
        guard let method = object["method"]?.stringValue else {
            // A response from the client: this server never sends requests, so nothing awaits it.
            if id != nil { return .none }
            return .reply(JSONRPC.error(id: .null, code: JSONRPCErrorCode.invalidRequest, message: "Invalid Request"))
        }
        let params = object["params"]?.objectValue ?? [:]

        guard let id, id != .null else {
            return handleNotification(method: method, params: params)
        }

        switch method {
        case "initialize":
            let requested = params["protocolVersion"]?.stringValue ?? ""
            let negotiated = Self.legacyVersions.contains(requested) ? requested : Self.legacyVersions[0]
            session.era = .legacy(version: negotiated)
            return .reply(JSONRPC.result(id: id, [
                "protocolVersion": .string(negotiated),
                "capabilities": Self.capabilities,
                "serverInfo": serverInfo,
                "instructions": .string(instructions),
            ]))
        case "ping":
            return .reply(JSONRPC.result(id: id, [:]))
        case "server/discover":
            if let requested = metaVersion(params), requested != Self.modernVersion {
                return .reply(unsupportedVersion(id: id, requested: requested))
            }
            return .reply(JSONRPC.result(id: id, modern([
                "supportedVersions": [.string(Self.modernVersion)],
                "capabilities": Self.capabilities,
                "instructions": .string(instructions),
                "ttlMs": .int(Self.toolsListTTLMilliseconds),
                "cacheScope": "private",
            ])))
        default:
            break
        }

        let isModern: Bool
        if let requested = metaVersion(params) {
            guard requested == Self.modernVersion else {
                return .reply(unsupportedVersion(id: id, requested: requested))
            }
            guard params["_meta"]?[Self.metaCapabilitiesKey] != nil else {
                return .reply(JSONRPC.error(
                    id: id,
                    code: JSONRPCErrorCode.invalidParams,
                    message: "Missing _meta[\"\(Self.metaCapabilitiesKey)\"]"
                ))
            }
            isModern = true
        } else if case .legacy = session.era {
            isModern = false
        } else {
            // Neither era: no handshake happened and the request carries no version. This text is
            // the only diagnostic such a client can show its user.
            let versions = ([Self.modernVersion] + Self.legacyVersions).joined(separator: ", ")
            return .reply(JSONRPC.error(
                id: id,
                code: JSONRPCErrorCode.invalidParams,
                message: "Send `initialize` first or include _meta[\"\(Self.metaVersionKey)\"]. Supported protocol versions: \(versions)."
            ))
        }

        switch method {
        case "tools/list":
            var result: [String: JSONValue] = ["tools": .array(tools.map(\.json))]
            if isModern {
                result["ttlMs"] = .int(Self.toolsListTTLMilliseconds)
                result["cacheScope"] = "private"
                return .reply(JSONRPC.result(id: id, modern(result)))
            }
            return .reply(JSONRPC.result(id: id, .object(result)))
        case "tools/call":
            guard let name = params["name"]?.stringValue else {
                return .reply(JSONRPC.error(id: id, code: JSONRPCErrorCode.invalidParams, message: "Missing tool name"))
            }
            guard tools.contains(where: { $0.name == name }) else {
                return .reply(JSONRPC.error(id: id, code: JSONRPCErrorCode.invalidParams, message: "Unknown tool: \(name)"))
            }
            let arguments: [String: JSONValue]
            switch params["arguments"] {
            case nil, .null?: arguments = [:]
            case .object(let value)?: arguments = value
            default:
                return .reply(JSONRPC.error(id: id, code: JSONRPCErrorCode.invalidParams, message: "`arguments` must be an object"))
            }
            return .callTool(id: id, name: name, arguments: arguments, modern: isModern)
        case "resources/list":
            var result: [String: JSONValue] = ["resources": [MCPChangeResource.listing]]
            if isModern {
                result["ttlMs"] = .int(MCPChangeResource.listTTLMilliseconds)
                result["cacheScope"] = "private"
                return .reply(JSONRPC.result(id: id, modern(result)))
            }
            return .reply(JSONRPC.result(id: id, .object(result)))
        case "resources/read":
            guard params["uri"]?.stringValue == MCPChangeResource.uri else {
                return .reply(unknownResource(id: id, params: params, modern: isModern))
            }
            var result: [String: JSONValue] = ["contents": MCPChangeResource.contents]
            if isModern {
                result["ttlMs"] = .int(MCPChangeResource.listTTLMilliseconds)
                result["cacheScope"] = "private"
                return .reply(JSONRPC.result(id: id, modern(result)))
            }
            return .reply(JSONRPC.result(id: id, .object(result)))
        case "resources/subscribe" where !isModern, "resources/unsubscribe" where !isModern:
            guard params["uri"]?.stringValue == MCPChangeResource.uri else {
                return .reply(unknownResource(id: id, params: params, modern: false))
            }
            return method == "resources/subscribe" ? .subscribe(id: id) : .unsubscribe(id: id)
        case "subscriptions/listen" where isModern:
            let requested = params["notifications"]?.objectValue ?? [:]
            let uris = requested["resourceSubscriptions"]?.arrayValue?.compactMap(\.stringValue) ?? []
            let filter = MCPListenFilter(
                changes: uris.contains(MCPChangeResource.uri),
                toolsListChanged: requested["toolsListChanged"] == true
            )
            // Nothing this server can send was asked for: an empty acknowledgment would leave the
            // client holding a stream that never speaks.
            guard filter.changes || filter.toolsListChanged else {
                return .reply(JSONRPC.error(
                    id: id,
                    code: JSONRPCErrorCode.invalidParams,
                    message: "This server sends only resource updates for \(MCPChangeResource.uri) (put it in notifications.resourceSubscriptions) and tool list changes (notifications.toolsListChanged)"
                ))
            }
            return .listen(id: id, filter: filter)
        default:
            return .reply(JSONRPC.error(id: id, code: JSONRPCErrorCode.methodNotFound, message: "Method not found: \(method)"))
        }
    }

    // MARK: - Change notifications

    /// Legacy: the answer to `resources/subscribe` / `resources/unsubscribe`.
    func subscribeResponse(id: JSONValue) -> JSONValue {
        JSONRPC.result(id: id, [:])
    }

    /// Modern: the first message on a `subscriptions/listen` stream, with the part of the filter
    /// the stream will carry.
    func listenAcknowledgment(id: JSONValue, filter: MCPListenFilter) -> JSONValue {
        var accepted: [String: JSONValue] = [:]
        if filter.changes { accepted["resourceSubscriptions"] = [.string(MCPChangeResource.uri)] }
        if filter.toolsListChanged { accepted["toolsListChanged"] = true }
        return [
            "jsonrpc": "2.0",
            "method": "notifications/subscriptions/acknowledged",
            "params": [
                "_meta": .object([Self.subscriptionIDKey: id]),
                "notifications": .object(accepted),
            ],
        ]
    }

    /// The mail tools came or went. `subscriptionID`: the `subscriptions/listen` request id
    /// (modern); `nil` on a legacy session.
    func toolsListChanged(subscriptionID: JSONValue?) -> JSONValue {
        var message: [String: JSONValue] = ["jsonrpc": "2.0", "method": "notifications/tools/list_changed"]
        if let subscriptionID { message["params"] = ["_meta": .object([Self.subscriptionIDKey: subscriptionID])] }
        return .object(message)
    }

    /// `subscriptionID`: the `subscriptions/listen` request id (modern); `nil` for a legacy
    /// subscription.
    func resourceUpdated(subscriptionID: JSONValue?) -> JSONValue {
        var params: [String: JSONValue] = ["uri": .string(MCPChangeResource.uri)]
        if let subscriptionID { params["_meta"] = .object([Self.subscriptionIDKey: subscriptionID]) }
        return ["jsonrpc": "2.0", "method": "notifications/resources/updated", "params": .object(params)]
    }

    /// Modern: a refused `subscriptions/listen` (the client is not allowed to read).
    func listenRefused(id: JSONValue, message: String) -> JSONValue {
        JSONRPC.error(id: id, code: JSONRPCErrorCode.invalidRequest, message: message)
    }

    static let subscriptionIDKey = "io.modelcontextprotocol/subscriptionId"

    private func unknownResource(id: JSONValue, params: [String: JSONValue], modern isModern: Bool) -> JSONValue {
        let uri = params["uri"]?.stringValue ?? ""
        // 2026-07-28 answers an unknown resource with Invalid Params; earlier revisions used -32002.
        return JSONRPC.error(
            id: id,
            code: isModern ? JSONRPCErrorCode.invalidParams : JSONRPCErrorCode.resourceNotFound,
            message: "Unknown resource: \(uri). The only resource is \(MCPChangeResource.uri)."
        )
    }

    func toolCallResponse(id: JSONValue, result: MCPToolResult, modern isModern: Bool) -> JSONValue {
        guard isModern, case .object(let object) = result.json else {
            return JSONRPC.result(id: id, result.json)
        }
        return JSONRPC.result(id: id, modern(object))
    }

    // MARK: - Helpers

    private func handleNotification(method: String, params: [String: JSONValue]) -> MCPDispatch {
        if method == "notifications/cancelled", let requestID = params["requestId"] {
            return .cancel(requestID: requestID)
        }
        // `notifications/initialized` and anything unknown: notifications get no answer.
        return .none
    }

    private func metaVersion(_ params: [String: JSONValue]) -> String? {
        params["_meta"]?[Self.metaVersionKey]?.stringValue
    }

    private func modern(_ result: [String: JSONValue]) -> JSONValue {
        var result = result
        result["resultType"] = "complete"
        var meta = result["_meta"]?.objectValue ?? [:]
        meta[Self.metaServerInfoKey] = serverInfo
        result["_meta"] = .object(meta)
        return .object(result)
    }

    private func unsupportedVersion(id: JSONValue, requested: String) -> JSONValue {
        JSONRPC.error(
            id: id,
            code: JSONRPCErrorCode.unsupportedProtocolVersion,
            message: "Unsupported protocol version",
            data: [
                "supported": .array(([Self.modernVersion] + Self.legacyVersions).map(JSONValue.string)),
                "requested": .string(requested),
            ]
        )
    }
}
