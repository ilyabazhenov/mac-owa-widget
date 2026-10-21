import Foundation
import Security
import XCTest
@testable import OWAWidget

/// Order of the Security calls behind `KeychainService.save`, with the calls faked: the suite must
/// never create live Keychain items (see `SecureStoreKeyProviding`).
///
/// The password must always land in an item this app just created: any process of the user can
/// plant an item under our name without a prompt, so an in-place update could write the password
/// into someone else's item. And each failure must report its own status — the old `try?` delete
/// turned every delete failure into the add's `errSecDuplicateItem`.
final class KeychainServiceSaveTests: XCTestCase {
    private let accountID = UUID()

    func testExistingItemIsDeletedThenAddedFresh() throws {
        let recorder = CallRecorder(deleteStatus: errSecSuccess, addStatus: errSecSuccess)

        try KeychainService.save(password: "secret", accountID: accountID, calls: recorder.calls)

        XCTAssertEqual(recorder.log, ["delete", "add"])
        let query = try XCTUnwrap(recorder.deleteQuery)
        XCTAssertEqual(query[kSecAttrService] as? String, KeychainService.service)
        XCTAssertEqual(query[kSecAttrAccount] as? String, accountID.uuidString)
        XCTAssertNil(query[kSecValueData], "the match query must not carry the secret")

        let attributes = try XCTUnwrap(recorder.addAttributes)
        XCTAssertEqual(attributes[kSecAttrService] as? String, KeychainService.service)
        XCTAssertEqual(attributes[kSecAttrAccount] as? String, accountID.uuidString)
        XCTAssertEqual(attributes[kSecValueData] as? Data, Data("secret".utf8))
        XCTAssertEqual(
            attributes[kSecAttrAccessible] as? String,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
        )
    }

    func testMissingItemIsAdded() throws {
        let recorder = CallRecorder(deleteStatus: errSecItemNotFound, addStatus: errSecSuccess)

        try KeychainService.save(password: "secret", accountID: accountID, calls: recorder.calls)

        XCTAssertEqual(recorder.log, ["delete", "add"])
    }

    /// A refused delete must surface as itself, not fall through to an add that then reports a
    /// duplicate — exactly what hid the cause before.
    func testRefusedDeleteThrowsItsOwnStatusAndDoesNotAdd() {
        let recorder = CallRecorder(deleteStatus: errSecAuthFailed)

        XCTAssertThrowsError(
            try KeychainService.save(password: "secret", accountID: accountID, calls: recorder.calls)
        ) { error in
            XCTAssertEqual(error as? KeychainError, .saveFailed(errSecAuthFailed))
        }
        XCTAssertEqual(recorder.log, ["delete"])
    }

    /// A duplicate right after the delete is an item we cannot vouch for. Fail and record whether
    /// it is visible — never write the password into it.
    func testDuplicateAfterDeleteIsAnErrorNotAnUpdate() {
        let recorder = CallRecorder(deleteStatus: errSecSuccess, addStatus: errSecDuplicateItem)

        XCTAssertThrowsError(
            try KeychainService.save(password: "secret", accountID: accountID, calls: recorder.calls)
        ) { error in
            XCTAssertEqual(error as? KeychainError, .saveFailed(errSecDuplicateItem))
        }
        XCTAssertEqual(recorder.log, ["delete", "add", "lookup"])
    }

    func testOtherAddFailureSkipsTheLookup() {
        let recorder = CallRecorder(deleteStatus: errSecSuccess, addStatus: errSecAuthFailed)

        XCTAssertThrowsError(
            try KeychainService.save(password: "secret", accountID: accountID, calls: recorder.calls)
        ) { error in
            XCTAssertEqual(error as? KeychainError, .saveFailed(errSecAuthFailed))
        }
        XCTAssertEqual(recorder.log, ["delete", "add"])
    }

    func testSaveFailureMessagesKeepTheStatus() throws {
        let denied = try XCTUnwrap(KeychainError.saveFailed(errSecAuthFailed).errorDescription)
        XCTAssertTrue(denied.contains("Keychain Access"))
        XCTAssertTrue(denied.hasSuffix("(OSStatus -25293)"))

        let duplicate = try XCTUnwrap(KeychainError.saveFailed(errSecDuplicateItem).errorDescription)
        XCTAssertTrue(duplicate.contains(KeychainService.service))
        XCTAssertTrue(duplicate.hasSuffix("(OSStatus -25299)"))

        let other = try XCTUnwrap(KeychainError.saveFailed(errSecIO).errorDescription)
        XCTAssertEqual(other, "Keychain save failed (OSStatus \(errSecIO))")
    }
}

/// Records what `save` asks of the Keychain and answers with fixed statuses.
private final class CallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let deleteStatus: OSStatus
    private let addStatus: OSStatus
    private var _log: [String] = []
    private var _deleteQuery: [CFString: Any]?
    private var _addAttributes: [CFString: Any]?

    init(deleteStatus: OSStatus, addStatus: OSStatus = errSecSuccess) {
        self.deleteStatus = deleteStatus
        self.addStatus = addStatus
    }

    var log: [String] { lock.withLock { _log } }
    var deleteQuery: [CFString: Any]? { lock.withLock { _deleteQuery } }
    var addAttributes: [CFString: Any]? { lock.withLock { _addAttributes } }

    var calls: KeychainWriteCalls {
        KeychainWriteCalls(
            delete: { [self] query in
                lock.withLock {
                    _log.append("delete")
                    _deleteQuery = query
                }
                return deleteStatus
            },
            add: { [self] attributes in
                lock.withLock {
                    _log.append("add")
                    _addAttributes = attributes
                }
                return addStatus
            },
            lookup: { [self] _ in
                lock.withLock { _log.append("lookup") }
                return errSecItemNotFound
            }
        )
    }
}
