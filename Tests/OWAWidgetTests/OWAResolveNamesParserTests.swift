import XCTest
@testable import OWAWidget

final class OWAResolveNamesParserTests: XCTestCase {

    /// Anonymized shape of a live Exchange 2019 answer (2026-11-21).
    private let full = """
    <?xml version="1.0" encoding="utf-8"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>\
    <m:ResolveNamesResponse xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages" xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types">\
    <m:ResponseMessages><m:ResolveNamesResponseMessage ResponseClass="Success"><m:ResponseCode>NoError</m:ResponseCode>\
    <m:ResolutionSet TotalItemsInView="1" IncludesLastItemInRange="true"><t:Resolution>\
    <t:Mailbox><t:Name>U_12345</t:Name><t:EmailAddress>IIvanov@corp.ru</t:EmailAddress><t:RoutingType>SMTP</t:RoutingType><t:MailboxType>Mailbox</t:MailboxType></t:Mailbox>\
    <t:Contact><t:DisplayName>Иванов Иван Иванович</t:DisplayName><t:CompanyName/>\
    <t:EmailAddresses><t:Entry Key="EmailAddress1">SMTP:IIvanov@corp.ru</t:Entry><t:Entry Key="EmailAddress2">smtp:ivan.ivanov@corp.ru</t:Entry><t:Entry Key="EmailAddress3">X500:/o=corp</t:Entry></t:EmailAddresses>\
    <t:PhysicalAddresses><t:Entry Key="Business"><t:Street/><t:City>Москва</t:City><t:State/></t:Entry></t:PhysicalAddresses>\
    <t:ContactSource>ActiveDirectory</t:ContactSource><t:Department>Дирекция развития</t:Department>\
    <t:JobTitle>Системный архитектор</t:JobTitle><t:Manager>U_67890</t:Manager><t:OfficeLocation>Г-502</t:OfficeLocation>\
    <t:ManagerMailbox><t:Mailbox><t:Name>Петров Пётр</t:Name><t:EmailAddress>PPetrov@corp.ru</t:EmailAddress><t:MailboxType>Mailbox</t:MailboxType></t:Mailbox></t:ManagerMailbox>\
    <t:DirectReports><t:Mailbox><t:Name>Bot_AI</t:Name><t:EmailAddress>Bot_AI@corp.ru</t:EmailAddress></t:Mailbox>\
    <t:Mailbox><t:Name>Сидоров С.</t:Name><t:EmailAddress>SSidorov@corp.ru</t:EmailAddress></t:Mailbox></t:DirectReports>\
    </t:Contact></t:Resolution></m:ResolutionSet></m:ResolveNamesResponseMessage></m:ResponseMessages></m:ResolveNamesResponse></s:Body></s:Envelope>
    """

    func testParsesTheFullContact() throws {
        let profile = try XCTUnwrap(OWAResolveNamesParser.profile(fromXML: full, email: "iivanov@corp.ru"))
        XCTAssertEqual(profile, PersonProfile(
            name: "Иванов Иван Иванович", email: "IIvanov@corp.ru", isDistributionList: false,
            title: "Системный архитектор", department: "Дирекция развития", office: "Г-502", city: "Москва",
            company: nil, manager: OrgPerson(name: "Петров Пётр", email: "PPetrov@corp.ru", title: nil),
            directReportsCount: 2
        ))
    }

    func testFindsThePersonByASecondaryAddress() {
        XCTAssertEqual(OWAResolveNamesParser.profile(fromXML: full, email: "Ivan.Ivanov@corp.ru")?.email, "IIvanov@corp.ru")
        XCTAssertNil(OWAResolveNamesParser.profile(fromXML: full, email: "someone.else@corp.ru"))
    }

    func testNoResultsAndADistributionList() {
        let none = """
        <?xml version="1.0" encoding="utf-8"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>\
        <m:ResolveNamesResponse xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages"><m:ResponseMessages>\
        <m:ResolveNamesResponseMessage ResponseClass="Error"><m:MessageText>No results were found.</m:MessageText>\
        <m:ResponseCode>ErrorNameResolutionNoResults</m:ResponseCode></m:ResolveNamesResponseMessage></m:ResponseMessages>\
        </m:ResolveNamesResponse></s:Body></s:Envelope>
        """
        XCTAssertNil(OWAResolveNamesParser.profile(fromXML: none, email: "someone@gmail.com"))

        let list = """
        <?xml version="1.0" encoding="utf-8"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>\
        <m:ResolveNamesResponse xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages" xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types">\
        <m:ResponseMessages><m:ResolveNamesResponseMessage ResponseClass="Success"><m:ResponseCode>NoError</m:ResponseCode>\
        <m:ResolutionSet><t:Resolution><t:Mailbox><t:Name>Все сотрудники</t:Name><t:EmailAddress>all@corp.ru</t:EmailAddress>\
        <t:MailboxType>PublicDL</t:MailboxType></t:Mailbox></t:Resolution></m:ResolutionSet>\
        </m:ResolveNamesResponseMessage></m:ResponseMessages></m:ResolveNamesResponse></s:Body></s:Envelope>
        """
        let dl = OWAResolveNamesParser.profile(fromXML: list, email: "all@corp.ru")
        XCTAssertEqual(dl?.isDistributionList, true)
        XCTAssertEqual(dl?.name, "Все сотрудники")
        XCTAssertNil(dl?.manager)
        XCTAssertEqual(dl?.directReportsCount, 0)
    }

    func testRequestAsksForTheFullContactAndEscapesTheAddress() {
        let soap = OWAResolveNamesPayload.soap(email: "a<b>&c@corp.ru")
        XCTAssertTrue(soap.contains(#"ReturnFullContactData="true""#))
        XCTAssertTrue(soap.contains(#"ContactDataShape="AllProperties""#))
        XCTAssertTrue(soap.contains(#"SearchScope="ActiveDirectory""#))
        XCTAssertTrue(soap.contains("<m:UnresolvedEntry>a&lt;b&gt;&amp;c@corp.ru</m:UnresolvedEntry>"))
        XCTAssertNotNil(try? XMLDocument(xmlString: soap))
    }
}
