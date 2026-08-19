import Foundation
import Security

struct KeychainService {
    static let service = "com.owawidget.OWAWidget"

    static func save(password: String, accountID: UUID) throws {
        // Remove existing entry first (update pattern)
        try? delete(accountID: accountID)

        guard let data = password.data(using: .utf8) else {
            throw KeychainError.encodingFailed
        }

        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: accountID.uuidString,
            kSecValueData: data,
            // `AfterFirstUnlockThisDeviceOnly` is set for the day this app can use the
            // data-protection keychain, and does almost nothing today.
            //
            // Without `kSecUseDataProtectionKeychain: true` this item goes into the file-based
            // login keychain, where `kSecAttrAccessible` carries no weight: the keychain is
            // unlocked with the login password and the whole `login.keychain-db` is copied by Time
            // Machine and by Migration Assistant. So the `ThisDeviceOnly` half in particular is
            // *not* the guarantee its name suggests — the password does travel with a restore.
            //
            // Turning the attribute into a real one means opting into the data-protection
            // keychain, which needs a `keychain-access-groups` entitlement, which needs a
            // provisioning profile and a Developer ID. The app is ad-hoc signed (see the Makefile),
            // so that is not available yet; leaving the attribute in place costs nothing and makes
            // the switch a one-line change when it is.
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    static func load(accountID: UUID) throws -> String {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: accountID.uuidString,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let password = String(data: data, encoding: .utf8)
        else {
            throw KeychainError.notFound
        }
        return password
    }

    static func delete(accountID: UUID) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: accountID.uuidString
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
    }
}

enum KeychainError: Error, LocalizedError {
    case encodingFailed
    case saveFailed(OSStatus)
    case notFound
    case deleteFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .encodingFailed: "Failed to encode password"
        case .saveFailed(let s): "Keychain save failed (OSStatus \(s))"
        case .notFound: "Password not found in Keychain"
        case .deleteFailed(let s): "Keychain delete failed (OSStatus \(s))"
        }
    }
}
