import Foundation

/// The three MCP switches: the server itself, creating meetings, and asking about new clients.
///
/// They live in ``SecureStore``, not in `UserDefaults`. The preferences plist is writable by any
/// process of the user (`defaults write`), and these switches decide whether a program may read
/// the calendar at all: in `UserDefaults` a script could turn the server on and the question off
/// and read everything without the user ever seeing a panel. The encrypted store needs the master
/// key from the Keychain, which other programs cannot read without a system prompt.
struct MCPSettings: Codable, Equatable, Sendable {
    var serverEnabled = false
    /// Off by default and separate from the main switch: reading the calendar and sending
    /// invitations on the user's behalf are different decisions.
    var createMeetings = false
    /// On by default: a client the user has not seen before reads nothing until they allow it.
    var askNewClients = true
}

enum MCPSettingsStore {
    typealias Store = SecureCodableStore<MCPSettings>

    static let storageName = "mcpSettings"
    /// Where the switches lived before; read once to carry the user's choice over, then removed.
    static let legacyEnabledKey = "mcpServerEnabled"
    static let legacyCreateMeetingsKey = "mcpCreateMeetingsEnabled"
    static let legacyAskNewClientsKey = "mcpAskNewClients"
    static let legacyDefaultsKeys = [legacyEnabledKey, legacyCreateMeetingsKey, legacyAskNewClientsKey]

    static let shared: Store = makeStore()

    /// The legacy values are booleans, not an encoded blob, so `SecureCodableStore`'s own
    /// migration does not apply; ``load(from:defaults:)`` does it instead.
    static func makeStore(secureStore: SecureStore = .shared, defaults: UserDefaults = .standard) -> Store {
        Store(name: storageName, legacyKey: nil, store: secureStore, defaults: defaults, policy: .treatAsEmpty)
    }

    /// The saved switches, migrating them from `UserDefaults` on first run.
    ///
    /// An unreadable store gives the defaults (server off), not the legacy values: once the
    /// switches have moved, whatever sits under the old keys was written by someone else.
    static func load(from store: Store = shared, defaults: UserDefaults = .standard) -> MCPSettings {
        if let saved = store.load() {
            removeLegacy(from: defaults)
            return saved
        }
        guard store.lastLoadOutcome == .ok else { return MCPSettings() }

        var migrated = MCPSettings()
        migrated.serverEnabled = defaults.bool(forKey: legacyEnabledKey)
        migrated.createMeetings = defaults.bool(forKey: legacyCreateMeetingsKey)
        migrated.askNewClients = defaults.object(forKey: legacyAskNewClientsKey) as? Bool ?? true
        // Same order as every other migration: write, read back and compare, only then delete.
        if store.save(migrated), store.load() == migrated {
            removeLegacy(from: defaults)
        }
        return migrated
    }

    private static func removeLegacy(from defaults: UserDefaults) {
        for key in legacyDefaultsKeys where defaults.object(forKey: key) != nil {
            defaults.removeObject(forKey: key)
        }
    }
}

/// The switches as the tool calls see them. ``MCPServerService`` is the only writer; the tools
/// run off the main actor, so they read this copy instead of asking the service.
final class MCPSettingsSnapshot: @unchecked Sendable {
    private let lock = NSLock()
    private var value: MCPSettings

    init(_ value: MCPSettings) {
        self.value = value
    }

    var current: MCPSettings {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func update(_ newValue: MCPSettings) {
        lock.lock()
        value = newValue
        lock.unlock()
    }
}
