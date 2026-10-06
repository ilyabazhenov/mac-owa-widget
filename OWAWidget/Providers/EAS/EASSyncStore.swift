import Foundation

/// The persisted half of a synchronisation chain.
///
/// `SyncKey` and the items it describes are one unit. The key is a promise to the server that
/// "I already have everything up to here", and the server answers later calls with changes
/// only. A key kept without its items is therefore worse than no key at all: every later sync
/// returns a small delta, the calendar stays permanently empty, and nothing anywhere reports
/// an error. They are written and read together for that reason, and a snapshot that cannot be
/// decoded discards both.
struct EASSyncSnapshot: Codable, Sendable, Equatable {
    /// Bumped when the shape changes, so an old snapshot is discarded rather than misread.
    let version: Int
    let savedAt: Date
    let collectionId: String
    let syncKey: String
    /// Recorded because changing it changes what the server considers in scope, which
    /// invalidates the key: a filter change must restart the chain from "0".
    let filterType: Int
    let items: [EASCalendarItem]

    static let currentVersion = 1
}

protocol EASSyncStoring: Sendable {
    func load() -> EASSyncSnapshot?
    @discardableResult func save(_ snapshot: EASSyncSnapshot) -> Bool
    func clear()
}

/// Encrypted at rest, like every other cache here: the items carry meeting subjects, attendee
/// addresses, agendas and join links that frequently embed conference secrets.
struct EASSyncStore: EASSyncStoring {
    private let backing: SecureCodableStore<EASSyncSnapshot>

    static func storeName(for accountID: UUID) -> String {
        "eas-sync-\(accountID.uuidString)"
    }

    init(accountID: UUID, secureStore: SecureStore = .shared) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970

        backing = SecureCodableStore<EASSyncSnapshot>(
            name: Self.storeName(for: accountID),
            // No cleartext predecessor.
            legacyKey: nil,
            store: secureStore,
            // An unreadable container costs one full resynchronisation and nothing else.
            // Critically it returns nil for the *whole* snapshot, so a surviving key can
            // never be paired with missing items.
            policy: .treatAsEmpty,
            encoder: encoder,
            decoder: decoder
        )
    }

    func load() -> EASSyncSnapshot? {
        guard let snapshot = backing.load() else { return nil }
        guard snapshot.version == EASSyncSnapshot.currentVersion else { return nil }
        return snapshot
    }

    @discardableResult
    func save(_ snapshot: EASSyncSnapshot) -> Bool {
        backing.save(snapshot)
    }

    func clear() {
        backing.clear()
    }

    /// Deletes the persisted synchronization state for an account that was removed.
    static func clear(accountID: UUID) {
        EASSyncStore(accountID: accountID).clear()
    }
}

/// In-memory double for tests.
final class EASInMemorySyncStore: EASSyncStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: EASSyncSnapshot?

    init(_ initial: EASSyncSnapshot? = nil) { snapshot = initial }

    func load() -> EASSyncSnapshot? {
        lock.lock(); defer { lock.unlock() }
        return snapshot
    }

    @discardableResult
    func save(_ value: EASSyncSnapshot) -> Bool {
        lock.lock(); snapshot = value; lock.unlock()
        return true
    }

    func clear() {
        lock.lock(); snapshot = nil; lock.unlock()
    }
}
