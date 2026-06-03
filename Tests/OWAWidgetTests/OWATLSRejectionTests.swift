import XCTest
@testable import OWAWidget

/// Integration test for the core MITM-rejection property: a server presenting an
/// untrusted (self-signed) certificate must be rejected by OWAClient BEFORE any
/// credentials are sent, surfaced as `OWAError.untrustedCertificate`, and the reported
/// leaf fingerprint must match the server's actual certificate.
///
/// Requires a local self-signed HTTPS server. Run via `scripts/tls_rejection_check.sh`,
/// which sets OWA_TEST_TLS_URL / OWA_TEST_TLS_FINGERPRINT. Skipped during a plain
/// `swift test` so it never blocks the normal suite.
final class OWATLSRejectionTests: XCTestCase {

    func testUntrustedSelfSignedServerIsRejectedBeforeSendingCredentials() async throws {
        guard let urlString = ProcessInfo.processInfo.environment["OWA_TEST_TLS_URL"] else {
            throw XCTSkip("Set OWA_TEST_TLS_URL (run scripts/tls_rejection_check.sh) to run this integration test.")
        }
        let expectedFingerprint = ProcessInfo.processInfo.environment["OWA_TEST_TLS_FINGERPRINT"]?.lowercased()

        let client = try OWAClient(serverURL: urlString, username: "tester", password: "s3cret-should-never-leave")

        do {
            try await client.authenticate()
            XCTFail("SECURITY: authenticate() succeeded against an untrusted self-signed server — the connection should have been rejected.")
        } catch let error as OWAError {
            guard let info = error.untrustedCertificateInfo else {
                XCTFail("Connection was rejected (good) but not as untrustedCertificate — got \(error). The trust-prompt path would not trigger.")
                return
            }
            // Core property proven: rejected with the typed error before any request body.
            if let expected = expectedFingerprint {
                XCTAssertEqual(
                    info.fingerprint.lowercased(), expected,
                    "Reported leaf fingerprint must equal the server's real certificate (used by the 'trust this server' UI)."
                )
            }
        } catch {
            // Any throw means the connection was refused (credentials not leaked), but we
            // want the typed path so the trust UI works. Surface what we actually got.
            XCTFail("Expected OWAError.untrustedCertificate, got non-OWAError: \(error)")
        }
    }
}
