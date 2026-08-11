import XCTest
@testable import OWAWidget

/// Envelope shape mirrors a captured `GetCalendarEvent` response (Exchange 15.2.1748.10):
/// `Body.ResponseMessages.Items[].Items[].Body = { BodyType, IsTruncated, Value }`.
final class OWACalendarEventBodyParserTests: XCTestCase {

    private func response(item: [String: Any]) -> Data {
        let json: [String: Any] = [
            "Body": [
                "ResponseMessages": [
                    "Items": [["Items": [item]]],
                ],
            ],
        ]
        return try! JSONSerialization.data(withJSONObject: json)
    }

    /// The raw markup travels alongside the text so the panel can rebuild real tables from it.
    func testKeepsOriginalMarkupForHTMLBodies() throws {
        let data = response(item: [
            "Body": ["BodyType": "HTML", "Value": "<p>Повестка</p>"],
        ])

        XCTAssertEqual(OWACalendarEventBodyParser.body(fromJSONData: data)?.html, "<p>Повестка</p>")
    }

    func testPlainTextBodyCarriesNoMarkup() throws {
        let data = response(item: [
            "TextBody": ["BodyType": "Text", "Value": "Повестка в виде текста"],
        ])

        XCTAssertNil(OWACalendarEventBodyParser.body(fromJSONData: data)?.html)
    }

    func testExtractsFullHTMLBodyAsPlainText() throws {
        let data = response(item: [
            "Subject": "Груминг",
            "Preview": String(repeating: "x", count: 255),
            "Body": [
                "BodyType": "HTML",
                "IsTruncated": false,
                "Value": "<html><head><style>p{margin:0}</style></head><body><p>Повестка</p><p>и материалы</p></body></html>",
            ],
        ])

        XCTAssertEqual(OWACalendarEventBodyParser.body(fromJSONData: data)?.text, "Повестка\n\nи материалы")
    }

    /// The response envelope has a top-level `Body` of its own — it carries no `Value`
    /// and must never be mistaken for the item body.
    func testIgnoresResponseEnvelopeBody() {
        let data = response(item: ["Subject": "Без описания"])

        XCTAssertNil(OWACalendarEventBodyParser.body(fromJSONData: data)?.text)
    }

    func testPrefersPlainTextBodyOverHTML() {
        let data = response(item: [
            "TextBody": ["BodyType": "Text", "Value": "Повестка в виде текста"],
            "Body": ["BodyType": "HTML", "Value": "<p>Повестка в виде HTML</p>"],
        ])

        XCTAssertEqual(OWACalendarEventBodyParser.body(fromJSONData: data)?.text, "Повестка в виде текста")
    }

    /// Some builds label a plain-text body as HTML-free but still send markup; sniff the value.
    func testConvertsMarkupEvenWhenBodyTypeIsNotHTML() {
        let data = response(item: [
            "Body": ["BodyType": "Text", "Value": "<p>Повестка</p>"],
        ])

        XCTAssertEqual(OWACalendarEventBodyParser.body(fromJSONData: data)?.text, "Повестка")
    }

    func testBlankBodyIsTreatedAsMissing() {
        let data = response(item: [
            "Body": ["BodyType": "HTML", "Value": "<html><head><style>p{margin:0}</style></head><body><p>  </p></body></html>"],
        ])

        XCTAssertNil(OWACalendarEventBodyParser.body(fromJSONData: data)?.text)
    }

    func testMalformedPayloadReturnsNil() {
        XCTAssertNil(OWACalendarEventBodyParser.body(fromJSONData: Data("not json".utf8))?.text)
    }
}
