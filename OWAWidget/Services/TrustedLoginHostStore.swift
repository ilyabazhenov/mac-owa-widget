import Foundation

/// Hosts the user has explicitly allowed to receive an account's credentials, beyond the server
/// the account is configured against.
///
/// The sibling of ``TrustedCertificateStore``, and deliberately shaped like it: the same
/// AES-GCM-backed container, the same host-keyed map, the same "ask once, remember the answer"
/// contract. What is being protected is again integrity rather than secrecy — an attacker who
/// could quietly add a host here would defeat the check entirely, which is why this lives in
/// ``SecureStore`` (authenticated) and not in `UserDefaults`.
///
/// Access is thread-safe: reads happen on whatever thread a sync lands on.
enum TrustedLoginHostStore {
    typealias Store = SecureCodableStore<[String: [String]]>

    static let storageName = "trustedLoginHosts"

    private static let lock = NSLock()
    nonisolated(unsafe) private static var backing: Store = makeStore()
    nonisolated(unsafe) private static var cache: [String: Set<String>]?

    static func makeStore(
        secureStore: SecureStore = .shared,
        defaults: UserDefaults = .standard
    ) -> Store {
        Store(
            name: storageName,
            // Never had a cleartext predecessor — this store is new with the consent flow.
            legacyKey: nil,
            store: secureStore,
            defaults: defaults,
            // An approval that cannot be read back is treated as absent, which means the prompt
            // comes up again. Failing that way round costs one dialog; failing the other way would
            // silently hand out credentials on an unreadable store.
            policy: .treatAsEmpty
        )
    }

    /// Test seam: swaps the backing store and drops the in-memory cache.
    static func replaceStoreForTesting(_ store: Store) {
        lock.lock()
        defer { lock.unlock() }
        backing = store
        cache = nil
    }

    /// Key for the store: the configured server host. Approvals are scoped to the server that
    /// redirected, so allowing an identity provider for one Exchange server does not allow it for
    /// another one the user adds later.
    static func key(configuredHost: String) -> String {
        OWACredentialHostPolicy.normalizedHost(configuredHost)
    }

    static func approvedHosts(forKey key: String) -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return loadedCache()[key] ?? []
    }

    static func isApproved(loginHost: String, forKey key: String) -> Bool {
        let host = OWACredentialHostPolicy.normalizedHost(loginHost)
        guard !host.isEmpty else { return false }
        return approvedHosts(forKey: key).contains(host)
    }

    static func approve(loginHost: String, forKey key: String) {
        let host = OWACredentialHostPolicy.normalizedHost(loginHost)
        guard !host.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        var current = loadedCache()
        current[key, default: []].insert(host)
        persist(current)
    }

    /// Drops every approval for a server (account removed, or server URL changed).
    static func revoke(forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        var current = loadedCache()
        guard current.removeValue(forKey: key) != nil else { return }
        persist(current)
    }

    // MARK: - Backing state

    /// Caller must hold `lock`.
    private static func loadedCache() -> [String: Set<String>] {
        if let cache { return cache }
        let loaded = (backing.load() ?? [:]).mapValues(Set.init)
        cache = loaded
        return loaded
    }

    /// Caller must hold `lock`.
    @discardableResult
    private static func persist(_ value: [String: Set<String>]) -> Bool {
        cache = value
        return backing.save(value.mapValues { $0.sorted() })
    }
}
