import XCTest
@testable import OWAWidget

final class MeetingBodyLinkFormatterTests: XCTestCase {

    func testDetectsLinkWithNonASCIIPath() {
        let url = "https://wiki.example.com/spaces/TEAM/pages/123/PreSA.+Автоматическая+передача"
        let body = "Материалы ко встрече \(url) — посмотрите заранее"

        let links = MeetingBodyLinkFormatter.detectLinks(in: body)

        XCTAssertEqual(links.count, 1)
        // The whole URL is captured, Cyrillic tail included — the visible text stays verbatim
        // while the destination is percent-encoded, exactly like a browser address bar.
        XCTAssertEqual(links.first?.text, url)
        XCTAssertEqual(
            links.first?.url.absoluteString,
            "https://wiki.example.com/spaces/TEAM/pages/123/PreSA."
                + "+%D0%90%D0%B2%D1%82%D0%BE%D0%BC%D0%B0%D1%82%D0%B8%D1%87%D0%B5%D1%81%D0%BA%D0%B0%D1%8F"
                + "+%D0%BF%D0%B5%D1%80%D0%B5%D0%B4%D0%B0%D1%87%D0%B0"
        )
    }

    func testDetectsSeveralLinksInOrder() {
        let body = """
        Страничка с материалами https://wiki.example.com/pages/1
        Время можно списать сюда - https://tracker.example.com/browse/TASK-612
        """

        let links = MeetingBodyLinkFormatter.detectLinks(in: body)

        XCTAssertEqual(links.map(\.url.absoluteString), [
            "https://wiki.example.com/pages/1",
            "https://tracker.example.com/browse/TASK-612",
        ])
    }

    func testUpgradesHTTPToHTTPS() {
        let links = MeetingBodyLinkFormatter.detectLinks(in: "See http://wiki.example.com/page")

        XCTAssertEqual(links.map(\.url.absoluteString), ["https://wiki.example.com/page"])
        // The displayed text stays exactly as written in the invite.
        XCTAssertEqual(links.first?.text, "http://wiki.example.com/page")
    }

    /// Calendar bodies are server-controlled: only http(s) may become a clickable link.
    func testIgnoresNonWebSchemes() {
        XCTAssertTrue(MeetingBodyLinkFormatter.detectLinks(in: "Пишите на agenda@example.com").isEmpty)
        XCTAssertTrue(MeetingBodyLinkFormatter.detectLinks(in: "Открой file:///etc/passwd").isEmpty)
    }

    func testPlainBodyHasNoLinks() {
        XCTAssertTrue(MeetingBodyLinkFormatter.detectLinks(in: "Обсудим планы на квартал").isEmpty)
    }
}
