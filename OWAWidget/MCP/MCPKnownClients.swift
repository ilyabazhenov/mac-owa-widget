import Foundation

/// Whether a client may call tools.
enum MCPClientAccess: String, Codable, Equatable, Sendable {
    case allowed
    case denied
    /// Asked, not answered yet: no tool calls until the user decides.
    case pending
}

/// A client that has talked to the MCP server at least once, for the list in Settings → AI (MCP).
struct MCPKnownClient: Codable, Equatable, Identifiable, Sendable {
    var id: String { key }

    let key: String
    var name: String
    var executablePath: String
    var script: String?
    /// What the client called itself in `initialize` / `_meta`. Its own claim, shown as a hint.
    var declaredName: String?
    var lastKind: MCPPeerKind
    let firstSeen: Date
    var lastSeen: Date
    var access: MCPClientAccess
}

extension MCPKnownClient {
    private enum CodingKeys: String, CodingKey {
        case key, name, executablePath, script, declaredName, lastKind, firstSeen, lastSeen, access
    }

    /// Entries saved before the question existed have no `access`: the user already saw them in
    /// the list and got a notification, so they stay allowed rather than asking again.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(String.self, forKey: .key)
        name = try container.decode(String.self, forKey: .name)
        executablePath = try container.decode(String.self, forKey: .executablePath)
        script = try container.decodeIfPresent(String.self, forKey: .script)
        declaredName = try container.decodeIfPresent(String.self, forKey: .declaredName)
        lastKind = try container.decode(MCPPeerKind.self, forKey: .lastKind)
        firstSeen = try container.decode(Date.self, forKey: .firstSeen)
        lastSeen = try container.decode(Date.self, forKey: .lastSeen)
        access = try container.decodeIfPresent(MCPClientAccess.self, forKey: .access) ?? .allowed
    }
}

/// What a tool call from a client gets, given its entry in the list and the "ask" setting.
enum MCPClientAccessPolicy {
    enum Verdict: Equatable {
        case allow
        case deny
        case ask
    }

    static func verdict(for access: MCPClientAccess?, askNewClients: Bool) -> Verdict {
        switch access {
        case .allowed: return .allow
        case .denied: return .deny
        // Not in the list, or asked and not answered. With the question turned off the app
        // behaves as before it existed: a notification, and the client reads.
        case .pending, nil: return askNewClients ? .ask : .allow
        }
    }
}

/// The list logic, apart from storage so it can be tested without `SecureStore`.
enum MCPKnownClientList {
    static let maxCount = 50

    /// Records a connection. `isNew` is true the first time a key is seen: that is when the user
    /// gets a notification.
    static func record(
        _ identity: MCPClientIdentity,
        at date: Date,
        in list: [MCPKnownClient],
        newClientAccess: MCPClientAccess = .allowed
    ) -> (list: [MCPKnownClient], isNew: Bool) {
        guard identity.isResolved else { return (list, false) }
        var list = list
        let isNew: Bool
        if let index = list.firstIndex(where: { $0.key == identity.key }) {
            // The name and path follow the current version: an app updated in place keeps its key.
            list[index].name = identity.name
            list[index].executablePath = identity.executablePath
            list[index].script = identity.script
            list[index].lastKind = identity.kind
            list[index].lastSeen = date
            isNew = false
        } else {
            list.append(MCPKnownClient(
                key: identity.key,
                name: identity.name,
                executablePath: identity.executablePath,
                script: identity.script,
                declaredName: nil,
                lastKind: identity.kind,
                firstSeen: date,
                lastSeen: date,
                access: newClientAccess
            ))
            isNew = true
        }
        return (Array(sorted(list).prefix(maxCount)), isNew)
    }

    static func noteDeclaredName(_ name: String, forKey key: String, in list: [MCPKnownClient]) -> [MCPKnownClient] {
        guard let index = list.firstIndex(where: { $0.key == key }), list[index].declaredName != name else { return list }
        var list = list
        list[index].declaredName = name
        return list
    }

    static func setAccess(_ access: MCPClientAccess, forKey key: String, in list: [MCPKnownClient]) -> [MCPKnownClient] {
        guard let index = list.firstIndex(where: { $0.key == key }), list[index].access != access else { return list }
        var list = list
        list[index].access = access
        return list
    }

    static func sorted(_ list: [MCPKnownClient]) -> [MCPKnownClient] {
        list.sorted { $0.lastSeen > $1.lastSeen }
    }
}

/// Persisted through `SecureStore`: paths and script names say what the user runs.
enum MCPKnownClientsStore {
    typealias Store = SecureCodableStore<[MCPKnownClient]>

    static let storageName = "mcpKnownClients"
    static let shared: Store = makeStore()

    /// An unreadable list is rebuilt from the next connections; the cost is one repeated
    /// "new client" notification per client.
    static func makeStore(secureStore: SecureStore = .shared, defaults: UserDefaults = .standard) -> Store {
        Store(name: storageName, legacyKey: nil, store: secureStore, defaults: defaults, policy: .treatAsEmpty)
    }
}
