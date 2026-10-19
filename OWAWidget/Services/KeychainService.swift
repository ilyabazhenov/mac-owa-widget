import Foundation
import Security

struct KeychainService {
    static let service = "com.owawidget.OWAWidget"

    /// Writes the password for `accountID` into a freshly created item.
    ///
    /// Delete, then add — and both statuses are checked. The delete used to be `try?`, so a
    /// failure there surfaced only as the add's `errSecDuplicateItem`, which hid the cause.
    ///
    /// The order is also the safe one: in the file-based keychain any process of this user can
    /// delete our item and plant its own under the same name without a prompt (verified on a probe
    /// 2026-10-19). Updating in place would write the new password into such an item, readable by
    /// whoever its ACL trusts. A fresh add always gets our ACL, and a duplicate after a successful
    /// delete is reported, never retried as an update.
    static func save(
        password: String,
        accountID: UUID,
        calls: KeychainWriteCalls = .system
    ) throws {
        guard let data = password.data(using: .utf8) else {
            throw KeychainError.encodingFailed
        }

        let match: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: accountID.uuidString
        ]
        let logID = accountID.uuidString.prefix(8)

        let deleteStatus = calls.delete(match)
        guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
            DiagnosticLog.event("Keychain save item=accountPassword id=\(logID) delete status=\(deleteStatus)")
            throw KeychainError.saveFailed(deleteStatus)
        }

        var attributes = match
        attributes[kSecValueData] = data
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
        // provisioning profile. Releases are Developer ID signed now (see the Makefile), but no
        // profile is embedded and `make build` stays ad-hoc, so that is not available yet;
        // leaving the attribute in place costs nothing and makes the switch a one-line change
        // when it is.
        attributes[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let addStatus = calls.add(attributes)
        guard addStatus == errSecSuccess else {
            // A duplicate right after the delete means an item the delete could not see — a
            // default keychain left out of the search list, or a damaged keychain index — or one
            // that appeared in between. Whether a lookup finds it tells those apart in the log.
            let lookup = addStatus == errSecDuplicateItem ? " lookup=\(calls.lookup(match))" : ""
            DiagnosticLog.event(
                "Keychain save item=accountPassword id=\(logID) delete=\(deleteStatus) "
                    + "add status=\(addStatus)\(lookup)"
            )
            throw KeychainError.saveFailed(addStatus)
        }
        DiagnosticLog.event("Keychain save item=accountPassword id=\(logID) delete=\(deleteStatus) saved")
    }

    static func load(accountID: UUID) throws -> String {
        // The id prefix tells a live item apart from one left behind by a deleted account, which
        // is the only way to spot orphans without decrypting the account store.
        DiagnosticLog.event("Keychain access item=accountPassword id=\(accountID.uuidString.prefix(8))")
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

/// The Security calls `KeychainService.save` makes, injectable so tests can pin their order
/// without creating live Keychain items (see `SecureStoreKeyProviding` for why they must not).
struct KeychainWriteCalls: Sendable {
    var delete: @Sendable (_ query: [CFString: Any]) -> OSStatus
    var add: @Sendable (_ attributes: [CFString: Any]) -> OSStatus
    /// Diagnostics only: whether an item matching `query` is visible, without reading its data.
    var lookup: @Sendable (_ query: [CFString: Any]) -> OSStatus

    static let system = KeychainWriteCalls(
        delete: { SecItemDelete($0 as CFDictionary) },
        add: { SecItemAdd($0 as CFDictionary, nil) },
        lookup: { query in
            var attributesOnly = query
            attributesOnly[kSecReturnAttributes] = true
            attributesOnly[kSecMatchLimit] = kSecMatchLimitOne
            return SecItemCopyMatching(attributesOnly as CFDictionary, nil)
        }
    )
}

enum KeychainError: Error, LocalizedError, Equatable {
    case encodingFailed
    case saveFailed(OSStatus)
    case notFound
    case deleteFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .encodingFailed: "Failed to encode password"
        case .saveFailed(let s): Self.saveFailureDescription(s)
        case .notFound: "Password not found in Keychain"
        case .deleteFailed(let s): "Keychain delete failed (OSStatus \(s))"
        }
    }

    /// The raw status stays at the end of every message: it is what a screenshot from a user
    /// carries back, and the only thing that tells the cases below apart for certain.
    private static func saveFailureDescription(_ status: OSStatus) -> String {
        switch status {
        case errSecAuthFailed, errSecUserCanceled, errSecInteractionNotAllowed:
            return "macOS did not let OWAWidget save the password. If the login keychain is "
                + "locked or asked for its password, unlock it in Keychain Access and save "
                + "again. (OSStatus \(status))"
        case errSecDuplicateItem:
            return "Another keychain item already holds this account's password. Delete the "
                + "\u{201C}\(KeychainService.service)\u{201D} item in Keychain Access and save "
                + "again. (OSStatus \(status))"
        default:
            return "Keychain save failed (OSStatus \(status))"
        }
    }
}
