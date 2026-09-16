import Foundation

// MARK: - Errors

/// Failures raised inside the EAS layer.
///
/// These never reach `CalendarService` directly: ``EASErrorBridge`` translates them into
/// `OWAError` values, which is the vocabulary the sync status, the certificate-trust UI
/// and the authentication circuit breaker already speak.
enum EASError: Error, Sendable {
    /// Credentials were rejected. Under Basic authentication a 401 is a definitive
    /// rejection, not a challenge, so this must never be retried — see the lockout guard
    /// in ``EASClient``.
    case authenticationRejected

    /// ActiveSync is reachable but refused, typically because it is disabled for the mailbox.
    case forbidden(String)

    case http(Int, String)

    /// The response was not valid WBXML, or lacked an element the command requires.
    case protocolError(String)

    /// A command answered with a non-success `Status` value.
    case commandStatus(command: String, status: String)

    /// `FolderSync` returned no calendar folder.
    case calendarFolderNotFound

    /// The stored device identifier exists but could not be read. Minting a replacement
    /// would register a second device with Exchange, so this fails instead.
    case deviceIdentityUnreadable
}

extension EASError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .authenticationRejected:
            return "The server rejected the credentials."
        case .forbidden(let detail):
            return "Access denied. \(detail)"
        case .http(let code, let detail):
            return "HTTP \(code). \(detail)"
        case .protocolError(let message):
            return "Protocol error: \(message)"
        case .commandStatus(let command, let status):
            return "\(command) returned Status=\(status). \(EASError.explain(status))"
        case .calendarFolderNotFound:
            return "No calendar folder was found in the folder hierarchy."
        case .deviceIdentityUnreadable:
            return "The stored ActiveSync device identifier could not be read."
        }
    }

    /// Status codes worth naming. Everything else surfaces as the bare number, which is
    /// still enough to look up in [MS-ASCMD].
    static func explain(_ status: String) -> String {
        switch status {
        case "2":   return "Protocol error."
        case "3":   return "Invalid synchronisation key."
        case "4":   return "The server rejected the request as malformed."
        case "5":   return "Temporary server error."
        case "8":   return "Object not found."
        case "12":  return "The folder hierarchy changed; a FolderSync is required."
        case "139": return "The device was judged not provisionable."
        case "142": return "The device is not provisioned."
        case "143": return "The policy is stale; provisioning must be repeated."
        case "144": return "Invalid policy key."
        case "145": return "The server does not accept externally managed devices."
        case "165": return "The server requires a DeviceInformation block in the Provision request."
        case "177": return "The device is blocked by Exchange policy."
        default:    return ""
        }
    }
}

// MARK: - Device identity

/// What the client tells the server it is.
///
/// Every field is self-asserted — ActiveSync has no device attestation — but they are not
/// cosmetic: Exchange access rules match on `DeviceType`, `DeviceModel`, `DeviceOS` and
/// `DeviceUserAgent` (`New-ActiveSyncDeviceAccessRule`), and an administrator sees these
/// values in `Get-MobileDevice`. They are editable in the account settings because an
/// organisation that only admits known device types has to be matched by trial.
struct EASDeviceProfile: Codable, Sendable, Hashable {
    var deviceType: String
    var userAgent: String
    var model: String
    var friendlyName: String
    var osVersion: String

    static let `default` = EASDeviceProfile(
        deviceType: "OWAWidget",
        userAgent: "OWAWidget/1.0",
        model: "Mac",
        friendlyName: "OWAWidget",
        osVersion: "macOS"
    )

    init(
        deviceType: String = EASDeviceProfile.default.deviceType,
        userAgent: String = EASDeviceProfile.default.userAgent,
        model: String = EASDeviceProfile.default.model,
        friendlyName: String = EASDeviceProfile.default.friendlyName,
        osVersion: String = EASDeviceProfile.default.osVersion
    ) {
        self.deviceType = deviceType
        self.userAgent = userAgent
        self.model = model
        self.friendlyName = friendlyName
        self.osVersion = osVersion
    }

    /// Trimmed copy with empty fields replaced by their defaults, so a blank text field in
    /// the settings UI cannot produce a request the server rejects as malformed.
    var normalized: EASDeviceProfile {
        func pick(_ value: String, _ fallback: String) -> String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? fallback : trimmed
        }
        let d = EASDeviceProfile.default
        return EASDeviceProfile(
            deviceType: pick(deviceType, d.deviceType),
            userAgent: pick(userAgent, d.userAgent),
            model: pick(model, d.model),
            friendlyName: pick(friendlyName, d.friendlyName),
            osVersion: pick(osVersion, d.osVersion)
        )
    }
}

/// The per-account ActiveSync device identifier.
///
/// Generated once and kept. A regenerated identifier is not a harmless detail: it registers
/// a brand-new device partnership with Exchange, which the administrator sees, which counts
/// against the mailbox device quota, and which in an organisation running Allow/Block/Quarantine
/// rules can land in quarantine and raise an administrator notification. The server also keys
/// the synchronisation state on it, so a new identifier silently resets the calendar to a full
/// resynchronisation.
///
/// Hence the refusal below: if a container exists but cannot be decrypted, this throws rather
/// than minting a replacement.
enum EASDeviceIdentity {

    static func storeName(for accountID: UUID) -> String {
        "eas-device-\(accountID.uuidString)"
    }

    static func makeStore(for accountID: UUID) -> SecureCodableStore<String> {
        SecureCodableStore<String>(
            name: storeName(for: accountID),
            // No cleartext predecessor: this store is new with the EAS provider.
            legacyKey: nil,
            policy: .treatAsEmpty
        )
    }

    /// Deletes the device identity after its account is removed. Re-adding the account creates
    /// a new Exchange device partnership instead of silently reusing retained account data.
    static func clear(for accountID: UUID) {
        makeStore(for: accountID).clear()
    }

    /// 32 uppercase hexadecimal characters — the longest identifier ActiveSync accepts.
    static func generate() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").uppercased()
    }

    static func deviceId(
        for accountID: UUID,
        store: SecureCodableStore<String>? = nil
    ) throws -> String {
        let backing = store ?? makeStore(for: accountID)

        if let existing = backing.load(), !existing.isEmpty {
            return existing
        }
        // `load()` returns nil both for "nothing stored yet" and "stored but unreadable".
        // Only the first may mint a new identifier.
        guard backing.lastLoadOutcome == .ok else {
            throw EASError.deviceIdentityUnreadable
        }

        let fresh = generate()
        _ = backing.save(fresh)
        return fresh
    }
}

// MARK: - Folders

/// A folder from `FolderSync`.
struct EASFolder: Sendable, Hashable {
    let id: String
    let displayName: String
    let type: Int

    /// Folder type codes from [MS-ASCMD]. 8 is the mailbox's own calendar; 13 is a
    /// user-created one. Both hold appointments.
    var isCalendar: Bool { type == 8 || type == 13 }
    var isDefaultCalendar: Bool { type == 8 }
}

/// What `OPTIONS` reports about the endpoint.
struct EASServerCapabilities: Sendable {
    let protocolVersions: String
    let commands: String
    let server: String

    var supportsVersion141: Bool {
        protocolVersions.split(separator: ",").contains { $0.trimmingCharacters(in: .whitespaces) == "14.1" }
    }
}
