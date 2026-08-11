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

        XCTAssertEqual(OWACalendarEventBodyParser.plainBody(fromJSONData: data), "Повестка\n\nи материалы")
    }

    /// The response envelope has a top-level `Body` of its own — it carries no `Value`
    /// and must never be mistaken for the item body.
    func testIgnoresResponseEnvelopeBody() {
        let data = response(item: ["Subject": "Без описания"])

        XCTAssertNil(OWACalendarEventBodyParser.plainBody(fromJSONData: data))
    }

    func testPrefersPlainTextBodyOverHTML() {
        let data = response(item: [
            "TextBody": ["BodyType": "Text", "Value": "Повестка в виде текста"],
            "Body": ["BodyType": "HTML", "Value": "<p>Повестка в виде HTML</p>"],
        ])

        XCTAssertEqual(OWACalendarEventBodyParser.plainBody(fromJSONData: data), "Повестка в виде текста")
    }

    /// Some builds label a plain-text body as HTML-free but still send markup; sniff the value.
    func testConvertsMarkupEvenWhenBodyTypeIsNotHTML() {
        let data = response(item: [
            "Body": ["BodyType": "Text", "Value": "<p>Повестка</p>"],
        ])

        XCTAssertEqual(OWACalendarEventBodyParser.plainBody(fromJSONData: data), "Повестка")
    }

    func testBlankBodyIsTreatedAsMissing() {
        let data = response(item: [
            "Body": ["BodyType": "HTML", "Value": "<html><head><style>p{margin:0}</style></head><body><p>  </p></body></html>"],
        ])

        XCTAssertNil(OWACalendarEventBodyParser.plainBody(fromJSONData: data))
    }

    func testMalformedPayloadReturnsNil() {
        XCTAssertNil(OWACalendarEventBodyParser.plainBody(fromJSONData: Data("not json".utf8)))
    }
}
