import Foundation

/// A `Codable` value persisted through ``SecureStore``, with a one-time read-through migration
/// from the cleartext `UserDefaults` key it used to live under.
///
/// Migration order is the whole point and is deliberately paranoid: encode → write encrypted →
/// read it back and compare → only then delete the legacy key. A crash or a decryption problem at
/// any step leaves the legacy copy intact, so the worst case is "still cleartext", never
/// "data gone".
final class SecureCodableStore<Value: Codable>: @unchecked Sendable {
    /// What to do when a container exists but fails authentication.
    enum FailurePolicy {
        /// Value can be rebuilt from the server (event cache). Report empty and move on.
        case treatAsEmpty
        /// Value cannot be recovered without the user retyping it (accounts, history).
        /// Falls back to the legacy cleartext copy if it is still around.
        case fallBackToLegacy
    }

    private let name: String
    private let legacyKey: String?
    private let store: SecureStore
    private let defaults: UserDefaults
    private let policy: FailurePolicy
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let lock = NSLock()
    private var migrationAttempted = false
    private var storedLoadOutcome: LoadOutcome = .ok

    /// Whether the last ``load()`` found the store readable, for call sites that must tell
    /// "nothing stored yet" apart from "something is stored and we could not read it".
    ///
    /// The distinction is not cosmetic. Both cases return `nil`, but a UI that shows the
    /// first-run empty state for the second one invites the user to re-enter what is still on
    /// disk — and re-entering persists a fresh value over the container, turning a Keychain
    /// prompt the user can still accept into actual data loss.
    enum LoadOutcome: Equatable {
        /// The store was read, or is genuinely empty.
        case ok
        /// A container exists but this build could not turn it back into a value: the master key
        /// was unavailable, or the bytes were written by a schema it does not understand.
        case unreadable
    }

    var lastLoadOutcome: LoadOutcome {
        lock.lock()
        defer { lock.unlock() }
        return storedLoadOutcome
    }

    init(
        name: String,
        legacyKey: String?,
        store: SecureStore = .shared,
        defaults: UserDefaults = .standard,
        policy: FailurePolicy = .fallBackToLegacy,
        encoder: JSONEncoder = JSONEncoder(),
        decoder: JSONDecoder = JSONDecoder()
    ) {
        self.name = name
        self.legacyKey = legacyKey
        self.store = store
        self.defaults = defaults
        self.policy = policy
        self.encoder = encoder
        self.decoder = decoder
    }

    /// Decrypted value, or `nil` when nothing is stored yet. Never throws: every call site here is
    /// on a UI path where a thrown error would mean a blank popover or a crash at launch.
    func load() -> Value? {
        migrateIfNeeded()

        do {
            // No container at all: nothing has been stored yet under this name.
            guard let data = try store.read(name) else { return record(.ok, legacyValue()) }
            // Decrypts but does not decode — written by a schema this build cannot read. The
            // bytes are still there, so this is emphatically not an empty store.
            guard let decoded = try? decoder.decode(Value.self, from: data) else {
                return record(.unreadable, nil)
            }
            return record(.ok, decoded)
        } catch {
            DiagnosticLog.event("SecureStore read failed store=\(name) policy=\(policy)")
            switch policy {
            case .treatAsEmpty:
                return record(.unreadable, nil)
            case .fallBackToLegacy:
                // The cleartext copy still standing means the value survived after all.
                guard let legacy = legacyValue() else { return record(.unreadable, nil) }
                return record(.ok, legacy)
            }
        }
    }

    private func record(_ outcome: LoadOutcome, _ value: Value?) -> Value? {
        lock.lock()
        storedLoadOutcome = outcome
        lock.unlock()
        return value
    }

    @discardableResult
    func save(_ value: Value) -> Bool {
        // Migration has to run here too, not only in `load()`. A store whose very first operation
        // is a write would otherwise create the encrypted container while the cleartext legacy
        // key sat in `UserDefaults` untouched — and it would stay there forever, because the next
        // `load()` sees the container already exists and skips migrating.
        migrateIfNeeded()

        guard let data = try? encoder.encode(value) else { return false }
        do {
            try store.write(data, name: name)
            return true
        } catch {
            DiagnosticLog.event("SecureStore write failed store=\(name)")
            return false
        }
    }

    func clear() {
        store.remove(name)
        if let legacyKey { defaults.removeObject(forKey: legacyKey) }
    }

    // MARK: - Migration

    private func migrateIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        guard !migrationAttempted else { return }
        migrationAttempted = true

        guard let legacyKey, !store.exists(name) else { return }
        guard let legacyData = defaults.data(forKey: legacyKey) else { return }

        // Migrated as raw bytes, without checking that they decode into `Value`.
        //
        // An earlier version gated this on a successful decode, which quietly defeated the whole
        // feature: a blob written before a schema change fails to decode, so it was neither
        // migrated nor removed and stayed in the cleartext plist forever. Moving the bytes across
        // regardless removes the plaintext either way, and costs nothing when they turn out to be
        // undecodable — `load()` already returns nil for a container it cannot decode, exactly as
        // it did for the legacy key. Nothing is destroyed on the chance a later version can read
        // the shape that this one cannot.
        do {
            try store.write(legacyData, name: name)
            // Verify by reading back through the real path before dropping the cleartext copy.
            guard let roundTripped = try store.read(name), roundTripped == legacyData else {
                DiagnosticLog.event("SecureStore migration verify failed store=\(name)")
                store.remove(name)
                return
            }
            defaults.removeObject(forKey: legacyKey)
            DiagnosticLog.event("SecureStore migrated store=\(name) bytes=\(legacyData.count)")
        } catch {
            DiagnosticLog.event("SecureStore migration failed store=\(name)")
            store.remove(name)
        }
    }

    private func legacyValue() -> Value? {
        guard let legacyKey, let data = defaults.data(forKey: legacyKey) else { return nil }
        return try? decoder.decode(Value.self, from: data)
    }
}
