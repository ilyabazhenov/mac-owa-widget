import XCTest
@testable import OWAWidget

final class ConnectionTestMessageTests: XCTestCase {
    func testAuthenticationFailureDoesNotExposeDiagnostics() {
        let error = OWAError.authenticationFailed(
            "No CANARY. Final URL: https://owa.example.com/owa/auth.owa. Cookies: [BIGipServer]. Body: <html>secret</html>"
        )

        let message = ConnectionTestMessage.failure(for: error)

        XCTAssertFalse(message.contains("Final URL"))
        XCTAssertFalse(message.contains("Cookies"))
        XCTAssertFalse(message.contains("Body"))
        XCTAssertFalse(message.contains("BIGipServer"))
        XCTAssertEqual(message, "Не удалось подключиться к OWA. Проверьте адрес сервера, логин и пароль.")
    }
}
