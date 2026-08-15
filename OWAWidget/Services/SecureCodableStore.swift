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
            guard let data = try store.read(name) else { return legacyValue() }
            return try? decoder.decode(Value.self, from: data)
        } catch {
            DiagnosticLog.event("SecureStore read failed store=\(name) policy=\(policy)")
            switch policy {
            case .treatAsEmpty: return nil
            case .fallBackToLegacy: return legacyValue()
            }
        }
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
        // Only migrate what still decodes. Garbage in the legacy key is dropped, not re-encrypted.
        guard (try? decoder.decode(Value.self, from: legacyData)) != nil else { return }

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
