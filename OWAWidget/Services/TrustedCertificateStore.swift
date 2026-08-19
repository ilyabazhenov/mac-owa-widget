import CryptoKit
import Foundation
import Security

/// Persists SHA-256 fingerprints of leaf certificates that the user has explicitly
/// chosen to trust for a given host (manual "trust this server" for self-signed /
/// internal-CA Exchange servers).
///
/// Fingerprints are not secret; what matters is their integrity, because an attacker who could
/// silently add one would defeat the pin. That used to be the reason they lived in the Keychain.
/// ``SecureStore`` gives the same guarantee through the AES-GCM authentication tag, so they moved
/// out — and with them went a whole keychain item, which is one authorization dialog the user no
/// longer sees after every Sparkle update.
///
/// Access is thread-safe: the static API is called from the `URLSession` delegate queue.
enum TrustedCertificateStore {
    typealias Store = SecureCodableStore<[String: [String]]>

    static let storageName = "trustedCertificates"
    static let legacyKeychainService = "com.owawidget.OWAWidget.trustedcerts"

    private static let lock = NSLock()
    nonisolated(unsafe) private static var backing: Store = makeStore()
    nonisolated(unsafe) private static var cache: [String: Set<String>]?

    static func makeStore(
        secureStore: SecureStore = .shared,
        defaults: UserDefaults = .standard
    ) -> Store {
        Store(
            name: storageName,
            // Never lived in UserDefaults — the legacy source is the Keychain, drained below.
            legacyKey: nil,
            store: secureStore,
            defaults: defaults,
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

    /// Key for the store: host plus port, e.g. `mail.example.com:443`.
    static func key(host: String, port: Int) -> String {
        "\(host.lowercased()):\(port)"
    }

    /// Lowercase hex SHA-256 of the leaf certificate's DER representation, or `nil`.
    static func leafFingerprint(from trust: SecTrust) -> String? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first
        else { return nil }
        let der = SecCertificateCopyData(leaf) as Data
        return SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }

    /// Issuer, subject and validity of the leaf certificate, for the trust prompt to show
    /// alongside the fingerprint. Best effort: any field the certificate does not carry, or that
    /// this parser does not recognise, comes back `nil` rather than failing the whole read.
    static func leafDetails(from trust: SecTrust) -> ServerCertificateDetails? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else { return nil }
        return details(of: leaf)
    }

    static func details(of certificate: SecCertificate) -> ServerCertificateDetails {
        var issuer: String?
        var notBefore: Date?
        var notAfter: Date?

        let keys = [
            kSecOIDX509V1IssuerName,
            kSecOIDX509V1ValidityNotBefore,
            kSecOIDX509V1ValidityNotAfter
        ] as CFArray
        if let values = SecCertificateCopyValues(certificate, keys, nil) as? [CFString: Any] {
            issuer = commonName(inSection: values[kSecOIDX509V1IssuerName])
            notBefore = date(from: values[kSecOIDX509V1ValidityNotBefore])
            notAfter = date(from: values[kSecOIDX509V1ValidityNotAfter])
        }

        return ServerCertificateDetails(
            subject: SecCertificateCopySubjectSummary(certificate) as String?,
            issuer: issuer,
            notBefore: notBefore,
            notAfter: notAfter
        )
    }

    /// A distinguished name arrives as a property whose `value` is an array of `{label, value}`
    /// components, one per attribute. We want the common name; everything else is noise here.
    private static func commonName(inSection section: Any?) -> String? {
        guard let property = section as? [CFString: Any],
              let components = property[kSecPropertyKeyValue] as? [[CFString: Any]] else { return nil }
        for component in components
        where component[kSecPropertyKeyLabel] as? String == (kSecOIDCommonName as String) {
            if let value = component[kSecPropertyKeyValue] as? String { return value }
        }
        return nil
    }

    /// Validity dates come back as seconds since the reference date (2001-01-01), not as `Date`.
    private static func date(from section: Any?) -> Date? {
        guard let property = section as? [CFString: Any] else { return nil }
        if let number = property[kSecPropertyKeyValue] as? NSNumber {
            return Date(timeIntervalSinceReferenceDate: number.doubleValue)
        }
        return property[kSecPropertyKeyValue] as? Date
    }

    /// Replaces every fingerprint pinned for a host with this one.
    ///
    /// Used when a host that already had a pinned certificate presents a different one. Adding
    /// the new fingerprint next to the old would leave the previous certificate trusted forever,
    /// including one that was rotated *because* it was compromised — a pin that never forgets is
    /// weaker than it looks.
    static func replace(fingerprint: String, forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        var current = loadedCache()
        current[key] = [fingerprint]
        persist(current)
    }

    static func trustedFingerprints(forKey key: String) -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return loadedCache()[key] ?? []
    }

    static func isTrusted(fingerprint: String, forKey key: String) -> Bool {
        trustedFingerprints(forKey: key).contains(fingerprint)
    }

    static func trust(fingerprint: String, forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        var current = loadedCache()
        current[key, default: []].insert(fingerprint)
        persist(current)
    }

    /// Removes all trusted fingerprints for a host:port (e.g. on account removal).
    static func untrust(forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        var current = loadedCache()
        current.removeValue(forKey: key)
        persist(current)
        deleteLegacyKeychainItem(account: key)
    }

    // MARK: - Backing state

    /// Caller must hold `lock`.
    private static func loadedCache() -> [String: Set<String>] {
        if let cache { return cache }
        var loaded = (backing.load() ?? [:]).mapValues(Set.init)

        let migrated = readLegacyKeychainItems()
        if !migrated.isEmpty {
            for (key, fingerprints) in migrated {
                loaded[key, default: []].formUnion(fingerprints)
            }
            // Delete the originals only once the encrypted copy is actually on disk. Writing can
            // fail — the master key is itself a Keychain item the user can decline — and a pin the
            // user set by hand must never be dropped on the strength of a write that did not
            // happen. If it fails, this session still works from `cache` and the next launch
            // retries the whole drain.
            if persist(loaded) {
                for account in migrated.keys {
                    deleteLegacyKeychainItem(account: account)
                }
                DiagnosticLog.event("TrustedCertificateStore migrated hosts=\(migrated.count) from keychain")
            } else {
                DiagnosticLog.event("TrustedCertificateStore migration deferred hosts=\(migrated.count)")
            }
        }

        cache = loaded
        return loaded
    }

    /// Caller must hold `lock`. Returns whether the encrypted write succeeded.
    @discardableResult
    private static func persist(_ value: [String: Set<String>]) -> Bool {
        cache = value
        return backing.save(value.mapValues { $0.sorted() })
    }

    // MARK: - Legacy Keychain drain

    /// Reads every fingerprint the old build stored in the Keychain. **Read-only** — deleting is
    /// the caller's job, and only after the encrypted copy has been written.
    ///
    /// Reading costs one authorization dialog on the first launch after the update — the same one
    /// the old build showed anyway — and deleting afterwards means it never comes back.
    private static func readLegacyKeychainItems() -> [String: Set<String>] {
        // Never under test. This touches real login-keychain items, and the suite runs on the
        // developer's own machine against their live trusted-certificate entries.
        guard !SecureStore.isRunningTests else { return [:] }

        // Two passes on purpose. The macOS file-based keychain does not return item *data* for a
        // `kSecMatchLimitAll` query — asking for both at once yields attributes and nothing else —
        // so enumerate the accounts first, then fetch each payload individually.
        let enumerate: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: legacyKeychainService,
            kSecReturnAttributes: true,
            kSecMatchLimit: kSecMatchLimitAll
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(enumerate as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[CFString: Any]]
        else { return [:] }

        var migrated: [String: Set<String>] = [:]
        for item in items {
            guard let account = item[kSecAttrAccount] as? String else { continue }

            // Reading needs authorization and can fail — dialog dismissed, keychain locked. Skip
            // such items entirely so the next launch retries; nothing here removes anything.
            guard let joined = legacyPayload(account: account) else { continue }

            let fingerprints = Self.parseFingerprints(joined)
            guard !fingerprints.isEmpty else {
                // Nothing to lose, so this one can go immediately.
                deleteLegacyKeychainItem(account: account)
                continue
            }
            migrated[account] = fingerprints
        }
        return migrated
    }

    /// Newline-separated hex fingerprints, as the Keychain payload stored them.
    static func parseFingerprints(_ payload: String) -> Set<String> {
        Set(payload.split(separator: "\n").map(String.init).filter { !$0.isEmpty })
    }

    private static func legacyPayload(account: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: legacyKeychainService,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func deleteLegacyKeychainItem(account: String) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: legacyKeychainService,
            kSecAttrAccount: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
