import XCTest
@testable import OWAWidget

final class MeetingURLDetectorTests: XCTestCase {

    private let detector = MeetingURLDetector()

    func testDetectsKTalkInPlainText() {
        let text = "Подключение: https://alfabank.ktalk.ru/ibazhenov"

        let result = detector.detect(in: text)

        XCTAssertEqual(result?.url.absoluteString, "https://alfabank.ktalk.ru/ibazhenov")
        XCTAssertEqual(result?.platform, .ktalk)
    }

    func testDetectsKTalkInHrefWhenAnchorTextIsNotURL() {
        let html = #"<p>Ссылка: <a href="https://alfabank.ktalk.ru/ibazhenov">Подключиться</a></p>"#

        let result = detector.detect(in: html)

        XCTAssertEqual(result?.url.absoluteString, "https://alfabank.ktalk.ru/ibazhenov")
        XCTAssertEqual(result?.platform, .ktalk)
    }
}
