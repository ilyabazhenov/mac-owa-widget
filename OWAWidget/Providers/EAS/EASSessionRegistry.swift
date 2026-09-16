import Foundation
import CryptoKit

/// Keeps one ``EASAccountSession`` per account alive across provider rebuilds.
///
/// `CalendarService.rebuildProviders()` throws away every provider and builds new ones —
/// on launch, on any account edit, on a re-trust. The server, meanwhile, keeps a `SyncKey`
/// chain per device and collection. A session created per provider would mean two of them
/// advancing the same chain, and the failure is silent: each gets part of the changes and
/// neither notices the rest is missing.
actor EASSessionRegistry {

    static let shared = EASSessionRegistry()

    private struct Entry {
        let fingerprint: String
        let session: EASAccountSession
    }

    private var entries: [UUID: Entry] = [:]

    /// Returns the live session for `account`, creating one if the credentials or the server
    /// address changed since it was made.
    ///
    /// The fingerprint is a hash, never the password: this object outlives the provider, and
    /// there is no reason for it to hold a secret to answer "is this still the same account".
    func session(
        for account: CalendarAccount,
        password: String,
        makeClient: @Sendable (String) throws -> EASClient,
        makeStore: @Sendable (UUID) -> any EASSyncStoring = { EASSyncStore(accountID: $0) }
    ) throws -> EASAccountSession {
        let fingerprint = Self.fingerprint(account: account, password: password)

        if let existing = entries[account.id], existing.fingerprint == fingerprint {
            return existing.session
        }

        let deviceId = try EASDeviceIdentity.deviceId(for: account.id)
        let session = EASAccountSession(
            accountID: account.id,
            client: try makeClient(deviceId),
            store: makeStore(account.id)
        )
        entries[account.id] = Entry(fingerprint: fingerprint, session: session)
        return session
    }

    /// Drops the in-memory session for an account that was removed. Its encrypted snapshot and
    /// device identity are cleared by `CalendarService` as part of account removal.
    func evict(accountID: UUID) {
        entries.removeValue(forKey: accountID)
    }

    func evictAll() {
        entries.removeAll()
    }

    static func fingerprint(account: CalendarAccount, password: String) -> String {
        let profile = account.resolvedDeviceProfile
        // A change to any of these produces different requests, so the session must be rebuilt.
        let material = [
            account.serverURL,
            account.email,
            password,
            profile.deviceType,
            profile.userAgent,
            profile.model,
            profile.friendlyName,
            profile.osVersion,
        ].joined(separator: "\u{0}")

        let digest = SHA256.hash(data: Data(material.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
