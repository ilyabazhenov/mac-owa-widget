import XCTest
@testable import OWAWidget

@MainActor
final class ConnectionTestMessageTests: XCTestCase {
    func testAuthenticationFailureDoesNotExposeDiagnostics() {
        let error = OWAError.authenticationFailed(
            "No CANARY. Final URL: https://owa.example.com/owa/auth.owa. Cookies: [BIGipServer]. Body: <html>secret</html>"
        )
        let localization = LocalizationService(
            selectedLanguage: .russian,
            preferredLanguages: ["en-US"]
        )

        let message = ConnectionTestMessage.failure(for: error, localization: localization)

        XCTAssertFalse(message.contains("Final URL"))
        XCTAssertFalse(message.contains("Cookies"))
        XCTAssertFalse(message.contains("Body"))
        XCTAssertFalse(message.contains("BIGipServer"))
        XCTAssertEqual(message, "Не удалось подключиться к OWA. Проверьте адрес сервера, логин и пароль.")
    }

    func testHTTPErrorDoesNotExposeRawOWAJSON() {
        let error = OWAError.httpError(
            500,
            #"{"Body":{"ErrorCode":500,"ExceptionName":"MemberAccessException","FaultMessage":"Cannot create an abstract class.","ResponseCode":"ErrorInternalServerError"}}"#
        )

        let message = error.localizedDescription

        XCTAssertFalse(message.contains(#""Body""#))
        XCTAssertFalse(message.contains("ExceptionName"))
        XCTAssertEqual(message, "HTTP 500: Cannot create an abstract class.")
    }
}
