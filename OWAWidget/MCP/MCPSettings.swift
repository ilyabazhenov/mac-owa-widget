import Foundation

/// The MCP switches: the server itself, creating and cancelling meetings, asking about new
/// clients, and mail.
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
    /// Mail is a separate decision from the calendar, and each client is asked about it again.
    var mailRead = false
    /// Off by default: an email goes out only after the user confirms it in the app's panel.
    var mailSend = false
    /// Off by default: marking mail threads read or unread (`set_mail_read`). Reversible and
    /// sends nothing, so no panel asks; it still needs `mailRead`.
    var mailOrganize = false
    /// Off by default: moving conversations between folders and flagging them (`move_mail`,
    /// `set_mail_flag`). Undoable and sends nothing, so no panel asks; it still needs `mailRead`.
    var mailArrange = false
    /// Off by default and separate from `createMeetings`: cancelling tells every attendee.
    var cancelMeetings = false
    /// Off by default: answering invitations (`respond_to_meeting`), each answer confirmed in a panel.
    var respondMeetings = false
}

extension MCPSettings {
    private enum CodingKeys: String, CodingKey {
        case serverEnabled, createMeetings, askNewClients, mailRead, mailSend, mailOrganize, mailArrange, cancelMeetings, respondMeetings
    }

    /// Settings saved before a switch existed lack its key: it takes its default (off).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        serverEnabled = try container.decodeIfPresent(Bool.self, forKey: .serverEnabled) ?? false
        createMeetings = try container.decodeIfPresent(Bool.self, forKey: .createMeetings) ?? false
        askNewClients = try container.decodeIfPresent(Bool.self, forKey: .askNewClients) ?? true
        mailRead = try container.decodeIfPresent(Bool.self, forKey: .mailRead) ?? false
        mailSend = try container.decodeIfPresent(Bool.self, forKey: .mailSend) ?? false
        mailOrganize = try container.decodeIfPresent(Bool.self, forKey: .mailOrganize) ?? false
        mailArrange = try container.decodeIfPresent(Bool.self, forKey: .mailArrange) ?? false
        cancelMeetings = try container.decodeIfPresent(Bool.self, forKey: .cancelMeetings) ?? false
        respondMeetings = try container.decodeIfPresent(Bool.self, forKey: .respondMeetings) ?? false
    }
}

extension MCPSettings {
    /// Whether the switch behind `id` lets its tools work. The refusals (`setting_disabled`), the
    /// mail tools in `tools/list` and `settings` in `get_status` / `get_changes` all read this, so
    /// a client is never told a switch is on while the tool refuses. The mail switches below
    /// "read mail" count only while it is on: the settings window greys them out then.
    func isOn(_ id: MCPSettingID) -> Bool {
        switch id {
        case .createMeetings: createMeetings
        case .cancelMeetings: cancelMeetings
        case .respondMeetings: respondMeetings
        case .readMail: mailRead
        case .prepareMail: mailRead && mailSend
        case .markMail: mailRead && mailOrganize
        case .arrangeMail: mailRead && mailArrange
        }
    }

    /// `settings` of `get_status` and `get_changes`: every switch with its state and its title as
    /// the settings window shows it (the same text `setting` carries in a `setting_disabled`
    /// refusal).
    @MainActor
    var statusJSON: JSONValue {
        var fields: [String: JSONValue] = [:]
        for id in MCPSettingID.allCases {
            fields[id.rawValue] = ["enabled": .bool(isOn(id)), "title": .string(id.title)]
        }
        return .object(fields)
    }

    /// What connected clients must hear after the switches went from `old` to these.
    func push(since old: MCPSettings) -> MCPSettingsPush {
        MCPSettingsPush(
            switches: MCPSettingID.allCases.contains { isOn($0) != old.isOn($0) },
            toolList: MCPToolRegistry.tools(for: self).map(\.name) != MCPToolRegistry.tools(for: old).map(\.name)
        )
    }
}

/// The notifications a change of the switches calls for.
struct MCPSettingsPush: Equatable, Sendable {
    /// A switch in `settings` changed: `notifications/resources/updated` for `owawidget://changes`,
    /// so a subscribed client re-reads `settings` with `get_changes`.
    var switches: Bool
    /// The mail tools in `tools/list` changed: `notifications/tools/list_changed`.
    var toolList: Bool

    var isEmpty: Bool { !switches && !toolList }
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
    ///
    /// "First run" cannot be told apart from "someone deleted `mcpSettings.enc`": the file is the
    /// user's, and any of their processes can remove it, then write the old keys and wait for a
    /// restart. So the migration never carries "don't ask about new clients" over — the question
    /// stays on, and a client switched on that way still meets a panel. A user who had turned it
    /// off turns it off once more.
    static func load(from store: Store = shared, defaults: UserDefaults = .standard) -> MCPSettings {
        if let saved = store.load() {
            removeLegacy(from: defaults)
            return saved
        }
        guard store.lastLoadOutcome == .ok else { return MCPSettings() }

        var migrated = MCPSettings()
        migrated.serverEnabled = defaults.bool(forKey: legacyEnabledKey)
        migrated.createMeetings = defaults.bool(forKey: legacyCreateMeetingsKey)
        // Deliberately not read from `legacyAskNewClientsKey`, see above.
        migrated.askNewClients = true
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
