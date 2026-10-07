import Foundation

/// First line the bridge writes to the app's socket, before any MCP traffic.
///
/// A hint for the app's debug log, nothing more: anyone can open the socket and write this line.
/// The app identifies the client itself, from the socket's peer process, the bridge's code
/// signature and the bridge's parent (`MCPClientIdentifier` in the app target).
public struct MCPBridgeHello: Codable, Equatable, Sendable {
    public static let marker = "owawidget_bridge"

    public var owawidget_bridge: Int
    public var parent_pid: Int32
    public var parent_path: String?

    public init(parentPID: Int32, parentPath: String?) {
        self.owawidget_bridge = 1
        self.parent_pid = parentPID
        self.parent_path = parentPath
    }

    public func encodedLine() -> Data {
        (try? JSONEncoder().encode(self)) ?? Data("{}".utf8)
    }

    /// `nil` unless the line is a bridge hello. A client that connects without the bridge simply
    /// starts with an MCP message.
    public static func decode(_ line: Data) -> MCPBridgeHello? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object[marker] != nil else { return nil }
        return try? JSONDecoder().decode(MCPBridgeHello.self, from: line)
    }
}

/// What the bridge has to remember about the MCP stream, kept apart from the I/O so it can be
/// tested without sockets.
///
/// The bridge is mostly a pipe, with two jobs a pipe cannot do:
/// - **Requests in flight.** If the app goes away mid-request (a Sparkle update restarts it), the
///   client would wait for its own timeout. The bridge answers each pending request with an error
///   instead, so the model can retry at once.
/// - **Legacy `initialize`.** A handshake-era client initialises once per process. After the app
///   restarts, its new connection knows nothing about that, so the bridge replays the original
///   `initialize` under a private id and swallows the answer. Stateless (2026-07-28) clients need
///   nothing of the kind.
public struct MCPBridgeState: Sendable {
    public static let replayIDPrefix = "owawidget-bridge-replay-"
    public static let connectionLostCode = -32000

    /// Pending client request ids, keyed by their raw JSON form (`5`, `"abc"`).
    public private(set) var inFlight: Set<String> = []
    public private(set) var legacyInitialize: Data?
    private var replayCounter = 0
    private var pendingReplayIDs: Set<String> = []

    public init() {}

    /// Records a client -> app message. Call before forwarding it.
    public mutating func noteClientMessage(_ line: Data) {
        guard let object = Self.object(line) else { return }
        let method = object["method"] as? String
        if method == "initialize" {
            legacyInitialize = line
        }
        if method == "notifications/cancelled",
           let params = object["params"] as? [String: Any],
           let requestID = params["requestId"].flatMap(Self.rawID) {
            inFlight.remove(requestID)
            return
        }
        if method != nil, let id = object["id"].flatMap(Self.rawID) {
            inFlight.insert(id)
        }
    }

    /// Records an app -> client message. Returns `false` when the bridge must swallow it (the
    /// answer to a replayed `initialize`).
    public mutating func noteServerMessage(_ line: Data) -> Bool {
        guard let object = Self.object(line) else { return true }
        guard object["method"] == nil, let id = object["id"].flatMap(Self.rawID) else { return true }
        if pendingReplayIDs.remove(id) != nil {
            return false
        }
        inFlight.remove(id)
        return true
    }

    /// The connection to the app is gone: one error line per pending request, ready for stdout.
    public mutating func connectionLost(message: String) -> [Data] {
        let lines = inFlight.sorted().map { Self.errorLine(rawID: $0, code: Self.connectionLostCode, message: message) }
        inFlight.removeAll()
        pendingReplayIDs.removeAll()
        return lines
    }

    /// Lines to send first on a fresh connection. Empty for stateless clients.
    public mutating func replayLinesForNewConnection() -> [Data] {
        guard let original = legacyInitialize, var initialize = Self.object(original) else { return [] }
        replayCounter += 1
        let id = Self.replayIDPrefix + String(replayCounter)
        initialize["id"] = id
        guard let data = try? JSONSerialization.data(withJSONObject: initialize) else { return [] }
        pendingReplayIDs.insert(Self.rawID(id) ?? "\"\(id)\"")
        return [data]
    }

    /// Error answer to one request, for when the app cannot be reached at all.
    public static func errorLine(forRequest line: Data, code: Int, message: String) -> Data? {
        guard let object = object(line), object["method"] != nil,
              let id = object["id"].flatMap(rawID) else { return nil }
        return errorLine(rawID: id, code: code, message: message)
    }

    static func errorLine(rawID: String, code: Int, message: String) -> Data {
        let encodedMessage = (try? JSONSerialization.data(withJSONObject: [message], options: [.withoutEscapingSlashes]))
            .flatMap { String(data: $0, encoding: .utf8) }
            .map { String($0.dropFirst().dropLast()) } ?? "\"error\""
        return Data("{\"jsonrpc\":\"2.0\",\"id\":\(rawID),\"error\":{\"code\":\(code),\"message\":\(encodedMessage)}}".utf8)
    }

    private static func object(_ line: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: line) as? [String: Any]
    }

    /// Canonical JSON text of a JSON-RPC id, so `5` and `"5"` stay distinct.
    static func rawID(_ value: Any) -> String? {
        if let string = value as? String {
            guard let data = try? JSONSerialization.data(withJSONObject: [string]),
                  let text = String(data: data, encoding: .utf8) else { return nil }
            return String(text.dropFirst().dropLast())
        }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            return number.stringValue
        }
        return nil
    }
}
