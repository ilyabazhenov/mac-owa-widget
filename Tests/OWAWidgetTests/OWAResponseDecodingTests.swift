import XCTest
@testable import OWAWidget

final class OWAResponseDecodingTests: XCTestCase {

    func testDecodesTextBodyWhenRepresentedAsObject() throws {
        let data = Data(
            """
            {
              "Body": {
                "Items": [
                  {
                    "Subject": "Demo",
                    "TextBody": { "Value": "agenda object" }
                  }
                ]
              }
            }
            """.utf8
        )

        let response = try JSONDecoder().decode(OWAServiceResponse.self, from: data)
        let first = try XCTUnwrap(response.Body?.Items?.first)
        XCTAssertEqual(first.TextBody?.Value, "agenda object")
    }

    func testDecodesTextBodyWhenRepresentedAsString() throws {
        let data = Data(
            """
            {
              "Body": {
                "Items": [
                  {
                    "Subject": "Demo",
                    "TextBody": "agenda string"
                  }
                ]
              }
            }
            """.utf8
        )

        let response = try JSONDecoder().decode(OWAServiceResponse.self, from: data)
        let first = try XCTUnwrap(response.Body?.Items?.first)
        XCTAssertEqual(first.TextBody?.Value, "agenda string")
    }

    func testDecodesUniqueBodyAndPreviewFallbackFields() throws {
        let data = Data(
            """
            {
              "Body": {
                "Items": [
                  {
                    "Subject": "Demo",
                    "UniqueBody": { "Value": "<p>agenda unique</p>", "BodyType": "HTML" },
                    "Preview": "agenda preview"
                  }
                ]
              }
            }
            """.utf8
        )

        let response = try JSONDecoder().decode(OWAServiceResponse.self, from: data)
        let first = try XCTUnwrap(response.Body?.Items?.first)
        XCTAssertEqual(first.UniqueBody?.Value, "<p>agenda unique</p>")
        XCTAssertEqual(first.UniqueBody?.BodyType, "HTML")
        XCTAssertEqual(first.Preview, "agenda preview")
    }
}
