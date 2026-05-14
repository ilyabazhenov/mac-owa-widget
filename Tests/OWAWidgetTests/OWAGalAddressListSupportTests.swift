import XCTest
@testable import OWAWidget

final class OWAGalAddressListSupportTests: XCTestCase {

    func testPicksEnglishDefaultGALFromRootArray() throws {
        let data = Data(
            """
            [
              {"DisplayName": "All Rooms", "FolderId": {"Id": "rooms-id"}},
              {"DisplayName": "Default Global Address List", "FolderId": {"Id": "gal-123"}}
            ]
            """.utf8
        )
        XCTAssertEqual(OWAGalAddressListSupport.pickDefaultGlobalAddressListFolderId(from: data), "gal-123")
    }

    func testPicksRussianDisplayName() throws {
        let data = Data(
            #"""
            [{"DisplayName": "Глобальный список адресов по умолчанию", "FolderId": {"Id": "ru-gal"}}]
            """#.utf8
        )
        XCTAssertEqual(OWAGalAddressListSupport.pickDefaultGlobalAddressListFolderId(from: data), "ru-gal")
    }

    func testUnwrapsAspNetDWrapper() throws {
        let data = Data(
            """
            {"d": [{"DisplayName": "Default Global Address List", "FolderId": {"Id": "wrapped"}}]}
            """.utf8
        )
        XCTAssertEqual(OWAGalAddressListSupport.pickDefaultGlobalAddressListFolderId(from: data), "wrapped")
    }
}
