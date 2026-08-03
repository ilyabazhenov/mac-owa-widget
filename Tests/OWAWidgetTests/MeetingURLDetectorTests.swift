import XCTest
@testable import OWAWidget

final class MeetingURLDetectorTests: XCTestCase {

    private let detector = MeetingURLDetector()

    func testDetectsKTalkInPlainText() {
        let text = "Подключение: https://acme.ktalk.ru/ipetrov"

        let result = detector.detect(in: text)

        XCTAssertEqual(result?.url.absoluteString, "https://acme.ktalk.ru/ipetrov")
        XCTAssertEqual(result?.platform, .ktalk)
    }

    func testDetectsKTalkInHrefWhenAnchorTextIsNotURL() {
        let html = #"<p>Ссылка: <a href="https://acme.ktalk.ru/ipetrov">Подключиться</a></p>"#

        let result = detector.detect(in: html)

        XCTAssertEqual(result?.url.absoluteString, "https://acme.ktalk.ru/ipetrov")
        XCTAssertEqual(result?.platform, .ktalk)
    }

    func testDetectsKTalkWithoutSchemeAndNormalizesToHTTPS() {
        let text = "Подключение: acme.ktalk.ru/hlppwr2q3pab"

        let result = detector.detect(in: text)

        XCTAssertEqual(result?.url.absoluteString, "https://acme.ktalk.ru/hlppwr2q3pab")
        XCTAssertEqual(result?.platform, .ktalk)
    }

    func testDetectsKTalkWhenURLIsEscapedWithBackslashes() {
        let escaped = #"Подключение: https:\/\/acme.ktalk.ru\/hlppwr2q3pab"#

        let result = detector.detect(in: escaped)

        XCTAssertEqual(result?.url.absoluteString, "https://acme.ktalk.ru/hlppwr2q3pab")
        XCTAssertEqual(result?.platform, .ktalk)
    }
}
