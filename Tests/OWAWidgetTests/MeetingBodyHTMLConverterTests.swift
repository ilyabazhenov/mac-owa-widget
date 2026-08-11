import XCTest
@testable import OWAWidget

final class MeetingBodyHTMLConverterTests: XCTestCase {

    /// The full body comes back as a whole HTML document; a plain tag strip would paste the
    /// stylesheet into the description (in a captured response: 5242 bytes of HTML, ~530 of text).
    func testDropsHeadStyleAndScript() {
        let html = """
        <html><head><meta charset="utf-8"><style>p { margin: 0; font-family: "Calibri"; }</style></head>
        <body><p>Коллеги, привет!</p><script>alert(1)</script><p>Повестка ниже</p></body></html>
        """

        let text = MeetingBodyHTMLConverter.plainText(from: html)

        XCTAssertEqual(text, "Коллеги, привет!\nПовестка ниже")
    }

    func testBlockTagsBecomeLineBreaksWithoutBlankRuns() {
        let html = "<div><p>Первая</p><p></p><p></p><p>Вторая<br>Третья</p></div>"

        XCTAssertEqual(MeetingBodyHTMLConverter.plainText(from: html), "Первая\n\nВторая\nТретья")
    }

    func testDecodesNamedAndNumericEntities() {
        let html = "<p>&quot;Груминг&quot;&nbsp;&mdash; тема &#1084;&#1077;&#1089;&#1103;&#1094;&#1072; &amp; итоги</p>"

        XCTAssertEqual(MeetingBodyHTMLConverter.plainText(from: html), "\"Груминг\" — тема месяца & итоги")
    }

    /// Entities are decoded exactly once: a literal, escaped "&lt;" must survive as text.
    func testDoesNotDoubleDecodeEntities() {
        XCTAssertEqual(MeetingBodyHTMLConverter.plainText(from: "<p>&amp;lt;тег&amp;gt;</p>"), "&lt;тег&gt;")
    }

    func testAnchorWithURLTextIsNotDuplicated() {
        let html = #"<p>Материалы <a href="https://wiki.example.com/page">https://wiki.example.com/page</a></p>"#

        XCTAssertEqual(
            MeetingBodyHTMLConverter.plainText(from: html),
            "Материалы https://wiki.example.com/page"
        )
    }

    /// A labelled link would lose its destination on a plain tag strip — the href is kept so the
    /// link formatter can still make it clickable.
    func testAnchorWithLabelKeepsHref() {
        let html = #"<p>Время можно списать <a href="https://tracker.example.com/browse/TASK-612">сюда</a></p>"#

        XCTAssertEqual(
            MeetingBodyHTMLConverter.plainText(from: html),
            "Время можно списать сюда (https://tracker.example.com/browse/TASK-612)"
        )
    }

    func testAnchorHrefEntitiesAreDecodedOnce() {
        let html = #"<p><a href="https://wiki.example.com/s?a=1&amp;b=2">повестка</a></p>"#

        XCTAssertEqual(
            MeetingBodyHTMLConverter.plainText(from: html),
            "повестка (https://wiki.example.com/s?a=1&b=2)"
        )
    }

    func testNonBreakingSpacesAndTrailingWhitespaceAreNormalized() {
        let html = "<p>  Повестка\u{00A0}встречи   </p>\n\n<p>   </p>"

        XCTAssertEqual(MeetingBodyHTMLConverter.plainText(from: html), "Повестка встречи")
    }

    func testLooksLikeHTMLDetection() {
        XCTAssertTrue(MeetingBodyHTMLConverter.looksLikeHTML("<p>привет</p>"))
        XCTAssertTrue(MeetingBodyHTMLConverter.looksLikeHTML("текст с <br> внутри"))
        XCTAssertFalse(MeetingBodyHTMLConverter.looksLikeHTML("Обычный текст"))
        // A stray comparison must not be mistaken for markup.
        XCTAssertFalse(MeetingBodyHTMLConverter.looksLikeHTML("если a < b, то встречаемся"))
    }
}
