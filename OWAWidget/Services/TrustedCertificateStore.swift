import Foundation
import Security
import CryptoKit

/// Persists SHA-256 fingerprints of leaf certificates that the user has explicitly
/// chosen to trust for a given host (manual "trust this server" for self-signed /
/// internal-CA Exchange servers).
///
/// Fingerprints are not secret, but they are stored in the Keychain to protect their
/// integrity — an attacker who could silently add a fingerprint would defeat the pin.
/// Keychain access is thread-safe, so the static API is safe to call from the URLSession
/// delegate queue.
enum TrustedCertificateStore {
    private static let service = "com.owawidget.OWAWidget.trustedcerts"

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

    static func trustedFingerprints(forKey key: String) -> Set<String> {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let joined = String(data: data, encoding: .utf8)
        else { return [] }
        return Set(joined.split(separator: "\n").map(String.init).filter { !$0.isEmpty })
    }

    static func isTrusted(fingerprint: String, forKey key: String) -> Bool {
        trustedFingerprints(forKey: key).contains(fingerprint)
    }

    static func trust(fingerprint: String, forKey key: String) {
        var fingerprints = trustedFingerprints(forKey: key)
        fingerprints.insert(fingerprint)
        write(fingerprints, forKey: key)
    }

    /// Removes all trusted fingerprints for a host:port (e.g. on account removal).
    static func untrust(forKey key: String) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key
        ]
        SecItemDelete(query as CFDictionary)
    }

    private static func write(_ fingerprints: Set<String>, forKey key: String) {
        untrust(forKey: key)
        guard let data = fingerprints.sorted().joined(separator: "\n").data(using: .utf8) else { return }
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        SecItemAdd(query as CFDictionary, nil)
    }
}
