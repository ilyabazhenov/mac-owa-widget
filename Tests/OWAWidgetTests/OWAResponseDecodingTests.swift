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

    func testDecodesCalendarItemMetadataFields() throws {
        let data = Data(
            """
            {
              "Body": {
                "Items": [
                  {
                    "Subject": "Demo",
                    "IsCancelled": true,
                    "IsOrganizer": false,
                    "Categories": ["Alpha", "Beta"]
                  }
                ]
              }
            }
            """.utf8
        )

        let response = try JSONDecoder().decode(OWAServiceResponse.self, from: data)
        let first = try XCTUnwrap(response.Body?.Items?.first)
        XCTAssertEqual(first.IsCancelled, true)
        XCTAssertEqual(first.IsOrganizer, false)
        XCTAssertEqual(first.Categories, ["Alpha", "Beta"])
    }

    func testDecodesCategoriesWhenSingleString() throws {
        let data = Data(
            """
            {
              "Body": {
                "Items": [
                  {
                    "Subject": "Demo",
                    "Categories": "OnlyOne"
                  }
                ]
              }
            }
            """.utf8
        )

        let response = try JSONDecoder().decode(OWAServiceResponse.self, from: data)
        let first = try XCTUnwrap(response.Body?.Items?.first)
        XCTAssertEqual(first.Categories, ["OnlyOne"])
    }

    func testDecodesCategoriesWhenRepresentedAsObjects() throws {
        let data = Data(
            """
            {
              "Body": {
                "Items": [
                  {
                    "Subject": "Demo",
                    "Categories": [
                      { "Name": "Лиловая категория" },
                      { "DisplayName": "Blue category" }
                    ]
                  }
                ]
              }
            }
            """.utf8
        )

        let response = try JSONDecoder().decode(OWAServiceResponse.self, from: data)
        let first = try XCTUnwrap(response.Body?.Items?.first)
        XCTAssertEqual(first.Categories, ["Лиловая категория", "Blue category"])
    }

    func testDecodesCategoriesFromValueAndLowercaseKeys() throws {
        let data = Data(
            """
            {
              "Body": {
                "Items": [
                  {
                    "Subject": "Demo",
                    "Categories": [
                      { "value": "Лиловая категория" },
                      { "categoryName": "Green category" }
                    ]
                  }
                ]
              }
            }
            """.utf8
        )

        let response = try JSONDecoder().decode(OWAServiceResponse.self, from: data)
        let first = try XCTUnwrap(response.Body?.Items?.first)
        XCTAssertEqual(first.Categories, ["Лиловая категория", "Green category"])
    }
}
