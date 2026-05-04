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
            kSecValueData: data
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
