import XCTest
@testable import OWAWidget

final class OutlookCategoryColorTests: XCTestCase {
    private let accountID = UUID()

    private func event(categories: [String], colors: [String: Int]?, changeKey: String? = nil) -> CalendarEvent {
        CalendarEvent(
            id: "e1", title: "РГ Collection", startDate: Date(timeIntervalSince1970: 0),
            endDate: Date(timeIntervalSince1970: 1800), location: nil, bodyPreview: nil, joinURL: nil,
            platform: .generic, isAllDay: false, organizer: nil, accountID: accountID,
            categories: categories, categoryColors: colors, changeKey: changeKey
        )
    }

    // MARK: - CategoryList

    private let listXML = """
    <?xml version="1.0"?>
    <categories default="Красная категория" lastSavedSession="2" xmlns="CategoryList.xsd">
      <category name="Красная категория" color="0" keyboardShortcut="0" guid="{1}"/>
      <category name="Английский" color="7" keyboardShortcut="0" guid="{2}"/>
      <category name="Без цвета" color="-1" keyboardShortcut="0" guid="{3}"/>
      <category name="Странная" color="99" guid="{4}"/>
    </categories>
    """

    private func soap(xmlData: String) -> String {
        """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>
        <m:GetUserConfigurationResponse xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages" xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types">
        <m:ResponseMessages><m:GetUserConfigurationResponseMessage ResponseClass="Success">
        <m:ResponseCode>NoError</m:ResponseCode>
        <m:UserConfiguration><t:UserConfigurationName Name="CategoryList"><t:FolderId Id="AAA" ChangeKey="B"/></t:UserConfigurationName>
        <t:XmlData>\(xmlData)</t:XmlData></m:UserConfiguration>
        </m:GetUserConfigurationResponseMessage></m:ResponseMessages>
        </m:GetUserConfigurationResponse></s:Body></s:Envelope>
        """
    }

    func testParsesTheCategoryListFromTheSOAPAnswer() {
        let colors = OWACategoryListParser.colors(fromSOAP: soap(xmlData: Data(listXML.utf8).base64EncodedString()))
        XCTAssertEqual(colors, ["красная категория": 0, "английский": 7, "без цвета": -1, "странная": -1])
    }

    func testAnswerWithoutAListIsUnknown() {
        let notFound = """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>
        <m:GetUserConfigurationResponse xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages">
        <m:ResponseMessages><m:GetUserConfigurationResponseMessage ResponseClass="Error">
        <m:ResponseCode>ErrorItemNotFound</m:ResponseCode>
        </m:GetUserConfigurationResponseMessage></m:ResponseMessages>
        </m:GetUserConfigurationResponse></s:Body></s:Envelope>
        """
        XCTAssertNil(OWACategoryListParser.colors(fromSOAP: notFound))
        XCTAssertNil(OWACategoryListParser.colors(fromSOAP: soap(xmlData: "bm90IHhtbA==")))
    }

    func testRequestAsksForTheCalendarCategoryList() {
        let soap = OWACategoryListPayload.soap()
        XCTAssertTrue(soap.contains(#"<m:UserConfigurationName Name="CategoryList">"#))
        XCTAssertTrue(soap.contains(#"<t:DistinguishedFolderId Id="calendar"/>"#))
        XCTAssertTrue(soap.contains("<m:UserConfigurationProperties>XmlData</m:UserConfigurationProperties>"))
    }

    // MARK: - Meeting colours

    func testMeetingColoursComeFromTheListByNameIgnoringCase() {
        let list = ["английский": 7, "без цвета": -1]
        let colors = OWACalendarProvider.categoryColors(of: ["АНГЛИЙСКИЙ", "Без цвета", "Чужая"], in: list)
        XCTAssertEqual(colors, ["АНГЛИЙСКИЙ": 7])
        XCTAssertNil(OWACalendarProvider.categoryColors(of: ["Английский"], in: nil))
    }

    func testKnownListIsAuthoritative() {
        // Named after a colour but without one in the list: no colour, no guess.
        let meeting = event(categories: ["Желтая категория", "Английский"], colors: ["Английский": 7])
        XCTAssertNil(meeting.colorPreset(ofCategory: "Желтая категория"))
        XCTAssertEqual(meeting.categoryColorPreset, 7)
    }

    func testUnknownListFallsBackToTheName() {
        XCTAssertEqual(event(categories: ["Желтая категория"], colors: nil).categoryColorPreset, OutlookCategoryColor.yellow)
        XCTAssertEqual(event(categories: ["Blue category"], colors: nil).categoryColorPreset, OutlookCategoryColor.blue)
        XCTAssertEqual(event(categories: ["Лиловая категория"], colors: nil).categoryColorPreset, OutlookCategoryColor.purple)
        XCTAssertNil(event(categories: ["Product sync"], colors: nil).categoryColorPreset)
    }

    func testColoursSurviveTheCache() throws {
        let meeting = event(categories: ["Английский"], colors: ["Английский": 7])
        let decoded = try JSONDecoder().decode(CalendarEvent.self, from: JSONEncoder().encode(meeting))
        XCTAssertEqual(decoded.categoryColors, ["Английский": 7])
        XCTAssertEqual(decoded.withResponseType(.accepted).categoryColors, ["Английский": 7])
    }

    // MARK: - MCP

    func testMCPGivesCategoriesWithPresetColours() {
        let meeting = event(categories: ["Английский", "Без цвета"], colors: ["Английский": 7])
        XCTAssertEqual(MCPCalendarTools.categoriesJSON(meeting), .array([
            .object(["name": "Английский", "color": "preset7"]),
            .object(["name": "Без цвета"]),
        ]))
    }

    func testCategoryChangeIsReported() {
        let before = event(categories: ["Английский"], colors: [:], changeKey: "1")
        let after = event(categories: ["Английский", "Срочно"], colors: [:], changeKey: "2")
        XCTAssertEqual(CalendarChangeDetector.changedFields(before, after), ["categories"])
    }
}
