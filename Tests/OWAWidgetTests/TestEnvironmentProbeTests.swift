import XCTest
@testable import OWAWidget

/// Pins the backstop that keeps the suite away from the developer's real data.
///
/// This exists because the first version of it did not work: it keyed off
/// `XCTestConfigurationFilePath` / `XCTestSessionIdentifier`, which SwiftPM's runner does not set.
/// The consequence was not theoretical — `SecureStore.shared` wrote containers into the real
/// `~/Library/Application Support`, and the Keychain guard in ``TrustedCertificateStore`` stayed
/// open, so running `swift test` enumerated and deleted live login-keychain items.
final class TestEnvironmentBackstopTests: XCTestCase {

    func testTestEnvironmentIsDetected() {
        XCTAssertTrue(
            SecureStore.isRunningTests,
            "страховка не видит тестовое окружение — сьют пойдёт в реальные данные"
        )
    }

    func testDetectionDoesNotDependOnEnvironmentVariables() {
        // SwiftPM sets neither variable, so the check must stand on something else entirely.
        let environment = ProcessInfo.processInfo.environment
        XCTAssertNil(environment["XCTestConfigurationFilePath"])
        XCTAssertNil(environment["XCTestSessionIdentifier"])
        XCTAssertTrue(SecureStore.isRunningTests)
    }

    func testSharedStoreStaysOutOfApplicationSupport() {
        let path = SecureStore.shared.url(for: "probe").path
        XCTAssertFalse(
            path.contains("Application Support"),
            "общий store указывает на реальные данные пользователя: \(path)"
        )
    }

    func testSharedStoreUsesATemporaryDirectory() {
        let path = SecureStore.shared.url(for: "probe").path
        let temporary = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().path
        XCTAssertTrue(path.hasPrefix(temporary), "ожидался временный каталог, получено: \(path)")
    }
}
