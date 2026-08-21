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

    /// A Google invitation as it arrives through EventKit (probe dump, 2026-08-22): the Meet link
    /// ends a sentence, and a `tel.meet` dial-in URL follows a couple of lines later.
    func testDetectsGoogleMeetInInvitationTextAndIgnoresTheDialInLink() {
        let notes = """
        Присоединиться через Google Meet: https://meet.google.com/qzs-aqzm-ujj.
        Вы также можете позвонить по телефону: (RU) +7 499 951-64-31 PIN-код: 9393749296365#
        Дополнительные номера телефонов: https://tel.meet/qzs-aqzm-ujj?pin=9393749296365
        """

        let result = detector.detect(in: notes)

        XCTAssertEqual(result?.url.absoluteString, "https://meet.google.com/qzs-aqzm-ujj")
        XCTAssertEqual(result?.platform, .googleMeet)
    }
}
