import CryptoKit
import Foundation
import Security

/// Source of the symmetric key that protects everything `SecureStore` writes.
///
/// Exists as a protocol for one practical reason: `swift test` is a mandatory gate for
/// `make release-package`, and a test suite that reached into the real Keychain would create
/// live items and — after any rebuild changes the ad-hoc `cdhash` — block packaging behind a
/// modal dialog. Tests inject an in-memory key instead and never touch the Keychain.
protocol SecureStoreKeyProviding: Sendable {
    func key() throws -> SymmetricKey
}

enum SecureStoreError: Error, LocalizedError, Equatable {
    case keyUnavailable(OSStatus)
    case keyGenerationFailed(OSStatus)
    case notAContainer
    case unsupportedFormatVersion(UInt8)
    case unknownKeyID(UInt8)
    case authenticationFailed

    var errorDescription: String? {
        switch self {
        case .keyUnavailable(let s): "Secure store key unavailable (OSStatus \(s))"
        case .keyGenerationFailed(let s): "Secure store key generation failed (OSStatus \(s))"
        case .notAContainer: "File is not a secure store container"
        case .unsupportedFormatVersion(let v): "Unsupported secure store format version \(v)"
        case .unknownKeyID(let id): "Container sealed with unknown key id \(id)"
        case .authenticationFailed: "Secure store container failed authentication"
        }
    }
}

// MARK: - Key providers

/// Keychain-backed master key. One generic-password item, created on first use.
///
/// Deliberately the *only* item this feature adds to the login keychain: every additional item
/// costs the user one authorization dialog after each Sparkle update, because ad-hoc signing
/// gives the app a fresh `cdhash` — and therefore a fresh designated requirement — on every build.
/// Account passwords stay in ``KeychainService`` on purpose; moving them here would have saved a
/// dialog at the price of making the password unrecoverable if either the file or the key is lost.
struct KeychainSecureStoreKeyProvider: SecureStoreKeyProviding {
    static let service = "com.owawidget.OWAWidget.datakey"
    static let account = "master.v1"

    func key() throws -> SymmetricKey {
        if let existing = try loadKey() { return existing }
        return try createKey()
    }

    private func loadKey() throws -> SymmetricKey? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecAttrAccount: Self.account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, data.count == 32 else {
                throw SecureStoreError.keyUnavailable(status)
            }
            return SymmetricKey(data: data)
        case errSecItemNotFound:
            return nil
        default:
            throw SecureStoreError.keyUnavailable(status)
        }
    }

    private func createKey() throws -> SymmetricKey {
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }

        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecAttrAccount: Self.account,
            kSecValueData: data,
            // Aspirational, not load-bearing — see the note in ``KeychainService/save(password:accountID:)``.
            // This is the file-based login keychain, where `kSecAttrAccessible` has no effect.
            //
            // What the threat model above actually rests on is that the login keychain is itself
            // encrypted under the login password: a backup or a second local account gets the
            // sealed containers *and* a sealed key, and neither without that password.
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return key
        case errSecDuplicateItem:
            // Another thread won the race between `loadKey` and here; theirs is authoritative.
            guard let existing = try loadKey() else {
                throw SecureStoreError.keyGenerationFailed(status)
            }
            return existing
        default:
            throw SecureStoreError.keyGenerationFailed(status)
        }
    }
}

/// Key held in memory for the lifetime of the process. Used by tests.
struct InMemorySecureStoreKeyProvider: SecureStoreKeyProviding {
    private let value: SymmetricKey

    init(key: SymmetricKey = SymmetricKey(size: .bits256)) {
        self.value = key
    }

    func key() throws -> SymmetricKey { value }
}

/// Provider that always fails, so tests can exercise the degradation paths.
struct UnavailableSecureStoreKeyProvider: SecureStoreKeyProviding {
    func key() throws -> SymmetricKey { throw SecureStoreError.keyUnavailable(errSecItemNotFound) }
}

// MARK: - Store

/// Authenticated-encryption storage for everything the app keeps on disk.
///
/// Container layout — an 8-byte cleartext header followed by an `AES.GCM` sealed box:
///
///     0..3  magic "OWAW"
///     4     format version
///     5     key id (reserved for rotation)
///     6..7  reserved, must be zero
///     8..   nonce (12) | ciphertext | tag (16)
///
/// The header *and the storage name* are fed in as additional authenticated data. That binds a
/// container to its slot: swapping `accounts.enc` for `events.enc`, or rewriting the version byte
/// to claim an older format, fails the tag check. It does not prevent restoring an older copy of
/// the *same* file — replay protection is out of scope, since the threat model is offline reading
/// of the disk (backups, cloud-synced Library, another local account), not active tampering by a
/// process that could just read the key anyway.
final class SecureStore: @unchecked Sendable {
    static let magic: [UInt8] = Array("OWAW".utf8)
    static let currentFormatVersion: UInt8 = 1
    static let currentKeyID: UInt8 = 1
    static let headerLength = 8

    /// Shared instance used by the app. Tests build their own against a temporary directory —
    /// but the fallback below makes that a convenience rather than a requirement.
    static let shared = isRunningTests
        ? SecureStore(directory: testFallbackDirectory(), keyProvider: InMemorySecureStoreKeyProvider())
        : SecureStore(directory: SecureStore.defaultDirectory(), keyProvider: KeychainSecureStoreKeyProvider())

    /// `swift test` is a required gate for `make release-package`. A test that reached the real
    /// Keychain would create live items and, once a rebuild changed the ad-hoc `cdhash`, block
    /// packaging behind a modal authorization dialog with nobody at the keyboard in CI. Injecting
    /// a store per test is the intended style; this is the backstop for the call site that forgets.
    ///
    /// Detection is by loaded class, not by environment. An earlier version checked only
    /// `XCTestConfigurationFilePath` / `XCTestSessionIdentifier`, and SwiftPM's test runner sets
    /// neither — so the backstop silently did nothing, the suite wrote into the real Application
    /// Support, and the Keychain guard in ``TrustedCertificateStore`` never engaged. `XCTest` is
    /// linked into the test host and absent from the shipped app, which makes this both reliable
    /// and impossible to trip accidentally in production.
    static var isRunningTests: Bool {
        if NSClassFromString("XCTestCase") != nil { return true }
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
    }

    private static func testFallbackDirectory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("owawidget-tests-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
            .appendingPathComponent("store", isDirectory: true)
    }

    private let directory: URL
    private let keyProvider: SecureStoreKeyProviding
    private let lock = NSLock()
    private var cachedKey: SymmetricKey?

    init(directory: URL, keyProvider: SecureStoreKeyProviding) {
        self.directory = directory
        self.keyProvider = keyProvider
    }

    /// `~/Library/Application Support/OWAWidget/<bundle-id>/store`.
    ///
    /// Scoped by bundle identifier deliberately. `UserDefaults` is already partitioned that way,
    /// so the `.dev` build has always had its own accounts and cache; a shared directory would
    /// have merged them and let a debug run overwrite the installed app's data.
    static func defaultDirectory() -> URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Application Support", isDirectory: true)

        let bundleID = Bundle.main.bundleIdentifier ?? "com.owawidget.MacOwaWidget"
        return base
            .appendingPathComponent("OWAWidget", isDirectory: true)
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("store", isDirectory: true)
    }

    func url(for name: String) -> URL {
        directory.appendingPathComponent("\(name).enc", isDirectory: false)
    }

    var isKeyAvailable: Bool {
        (try? resolvedKey()) != nil
    }

    // MARK: Reading and writing

    /// Returns the decrypted payload, or `nil` when nothing is stored under `name`.
    /// Throws when a container exists but cannot be authenticated — callers decide whether that
    /// means "treat as empty" (regenerable caches) or "keep the legacy copy" (account data).
    func read(_ name: String) throws -> Data? {
        let fileURL = url(for: name)
        guard let container = try? Data(contentsOf: fileURL) else { return nil }
        return try open(container: container, name: name)
    }

    func write(_ payload: Data, name: String) throws {
        let container = try seal(payload: payload, name: name)
        try createDirectoryIfNeeded()
        let fileURL = url(for: name)
        try container.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }

    func remove(_ name: String) {
        try? FileManager.default.removeItem(at: url(for: name))
    }

    func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: url(for: name).path)
    }

    // MARK: Container internals

    func seal(payload: Data, name: String) throws -> Data {
        let key = try resolvedKey()
        let header = Self.header()
        let sealed = try AES.GCM.seal(
            payload,
            using: key,
            authenticating: Self.authenticatedData(header: header, name: name)
        )
        guard let combined = sealed.combined else { throw SecureStoreError.authenticationFailed }
        return header + combined
    }

    func open(container: Data, name: String) throws -> Data {
        guard container.count > Self.headerLength else { throw SecureStoreError.notAContainer }
        let header = Data(container.prefix(Self.headerLength))
        guard Array(header.prefix(4)) == Self.magic else { throw SecureStoreError.notAContainer }

        let version = header[header.startIndex + 4]
        guard version == Self.currentFormatVersion else {
            throw SecureStoreError.unsupportedFormatVersion(version)
        }
        let keyID = header[header.startIndex + 5]
        guard keyID == Self.currentKeyID else { throw SecureStoreError.unknownKeyID(keyID) }

        let key = try resolvedKey()
        let body = Data(container.dropFirst(Self.headerLength))
        guard let box = try? AES.GCM.SealedBox(combined: body) else {
            throw SecureStoreError.authenticationFailed
        }
        do {
            return try AES.GCM.open(
                box,
                using: key,
                authenticating: Self.authenticatedData(header: header, name: name)
            )
        } catch {
            throw SecureStoreError.authenticationFailed
        }
    }

    private static func header() -> Data {
        var bytes = magic
        bytes.append(currentFormatVersion)
        bytes.append(currentKeyID)
        bytes.append(contentsOf: [0, 0])
        return Data(bytes)
    }

    private static func authenticatedData(header: Data, name: String) -> Data {
        header + Data(name.utf8)
    }

    private func resolvedKey() throws -> SymmetricKey {
        lock.lock()
        defer { lock.unlock() }
        if let cachedKey { return cachedKey }
        let key = try keyProvider.key()
        cachedKey = key
        return key
    }

    private func createDirectoryIfNeeded() throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }
}
