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
            "description": .string(description),
            "inputSchema": inputSchema,
            "annotations": .object(annotations),
        ]
    }
}

/// Outcome of one tool call. Failures are tool results (`isError: true`) rather than JSON-RPC
/// errors, so the model reads the message and can correct its arguments or tell the user.
struct MCPToolResult: Sendable, Equatable {
    let structured: [String: JSONValue]?
    let errorMessage: String?

    static func success(_ structured: [String: JSONValue]) -> MCPToolResult {
        MCPToolResult(structured: structured, errorMessage: nil)
    }

    static func failure(_ message: String) -> MCPToolResult {
        MCPToolResult(structured: nil, errorMessage: message)
    }

    var isError: Bool { errorMessage != nil }

    var json: JSONValue {
        if let errorMessage {
            return [
                "content": [["type": "text", "text": .string(errorMessage)]],
                "isError": true,
            ]
        }
        let object = JSONValue.object(structured ?? [:])
        // The spec asks tools that return structured content to repeat it as text, for clients
        // that only read `content`. `structuredContent` stays an object for the legacy schemas.
        return [
            "content": [["type": "text", "text": .string(JSONLine.encodeString(object))]],
            "structuredContent": object,
            "isError": false,
        ]
    }
}

protocol MCPToolProviding: Sendable {
    var tools: [MCPToolDefinition] { get }
    func callTool(name: String, arguments: [String: JSONValue], client: String?) async -> MCPToolResult
}

/// Which MCP era a connection speaks. Decided by how the client opens: an `initialize` handshake
/// (2025-11-25 and earlier) or per-request `_meta` (2026-07-28).
enum MCPEra: Equatable, Sendable {
    case undetermined
    case legacy(version: String)
}

struct MCPSessionState: Sendable {
    var era: MCPEra = .undetermined
}

enum MCPDispatch: Equatable, Sendable {
    case reply(JSONValue)
    case none
    case cancel(requestID: JSONValue)
    case callTool(id: JSONValue, name: String, arguments: [String: JSONValue], modern: Bool)
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
    /// The tool set never changes at runtime, so clients may cache it for an hour.
    static let toolsListTTLMilliseconds: Int64 = 3_600_000

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
                "capabilities": ["tools": [:]],
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
                "capabilities": ["tools": [:]],
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
        default:
            return .reply(JSONRPC.error(id: id, code: JSONRPCErrorCode.methodNotFound, message: "Method not found: \(method)"))
        }
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
