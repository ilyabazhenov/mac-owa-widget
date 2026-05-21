import XCTest
@testable import OWAWidget

/// Покрытие чистого SOAP-генератора для EWS `CreateItem`.
/// Главные регрессии, которые тут ловятся:
///   • Не-экранированные `&<>"` в title/location/email сломали бы XML-парсер на сервере.
///   • Перестановка Required ↔ Optional уронит запрос на схеме EWS.
///   • `]]>` в agenda закроет CDATA преждевременно — встреча создастся с битым телом.
///   • Локаль/таймзона форматтера дат — Exchange ждёт `…Z` UTC.
final class OWACreateItemSOAPTests: XCTestCase {

    private let referenceStart = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14 22:13:20 UTC
    private let referenceEnd   = Date(timeIntervalSince1970: 1_700_000_000 + 1800)

    private func attendee(_ email: String, name: String = "Test") -> ResolvedAttendee {
        ResolvedAttendee(displayName: name, email: email, jobTitle: nil)
    }

    // MARK: - Базовая структура

    func testProducesValidEnvelopeWithExpectedHeader() {
        let soap = OWACreateCalendarEventPayload.createItemSOAP(
            title: "Sync",
            agenda: "",
            location: "",
            start: referenceStart,
            end: referenceEnd,
            requiredAttendees: [attendee("a@x.com")]
        )
        XCTAssertTrue(soap.hasPrefix("<?xml version=\"1.0\" encoding=\"utf-8\"?>"))
        XCTAssertTrue(soap.contains("<soap:Envelope"))
        XCTAssertTrue(soap.contains("<t:RequestServerVersion Version=\"Exchange2013_SP1\"/>"))
        XCTAssertTrue(soap.contains("<t:TimeZoneDefinition Id=\"UTC\"/>"))
        XCTAssertTrue(soap.contains("<m:CreateItem SendMeetingInvitations=\"SendToAllAndSaveCopy\">"))
        XCTAssertTrue(soap.contains("<t:DistinguishedFolderId Id=\"calendar\"/>"))
    }

    // MARK: - XML-эскейп пользовательских полей

    func testEscapesXMLSpecialsInTitle() {
        let soap = OWACreateCalendarEventPayload.createItemSOAP(
            title: "R&D <review> \"v2\"",
            agenda: "",
            location: "",
            start: referenceStart,
            end: referenceEnd,
            requiredAttendees: []
        )
        XCTAssertTrue(soap.contains("<t:Subject>R&amp;D &lt;review&gt; &quot;v2&quot;</t:Subject>"))
        // Сырая угловая скобка из title не должна протекать в payload как сырая.
        XCTAssertFalse(soap.contains("<t:Subject>R&D"))
    }

    func testEscapesXMLSpecialsInLocation() {
        let soap = OWACreateCalendarEventPayload.createItemSOAP(
            title: "T",
            agenda: "",
            location: "Room <A&B>",
            start: referenceStart,
            end: referenceEnd,
            requiredAttendees: []
        )
        XCTAssertTrue(soap.contains("<t:Location>Room &lt;A&amp;B&gt;</t:Location>"))
    }

    func testEscapesXMLSpecialsInEmailAddress() {
        // Сервер может не принять, но генератор не должен ломать XML.
        let soap = OWACreateCalendarEventPayload.createItemSOAP(
            title: "T",
            agenda: "",
            location: "",
            start: referenceStart,
            end: referenceEnd,
            requiredAttendees: [attendee("a&b@x.com")]
        )
        XCTAssertTrue(soap.contains("<t:EmailAddress>a&amp;b@x.com</t:EmailAddress>"))
    }

    // MARK: - Trim пустых полей

    func testOmitsLocationElementWhenEmpty() {
        let soap = OWACreateCalendarEventPayload.createItemSOAP(
            title: "T",
            agenda: "",
            location: "   ",  // whitespace-only тоже считается пустым
            start: referenceStart,
            end: referenceEnd,
            requiredAttendees: [attendee("a@x.com")]
        )
        XCTAssertFalse(soap.contains("<t:Location>"))
    }

    func testOmitsBodyElementWhenAgendaEmpty() {
        let soap = OWACreateCalendarEventPayload.createItemSOAP(
            title: "T",
            agenda: "\n  \n",
            location: "",
            start: referenceStart,
            end: referenceEnd,
            requiredAttendees: [attendee("a@x.com")]
        )
        XCTAssertFalse(soap.contains("<t:Body"))
    }

    // MARK: - CDATA защита

    func testAgendaWithCDATAEndIsNeutralizedBeforeWrapping() {
        // `]]>` в пользовательском вводе закрыл бы CDATA-секцию преждевременно.
        let soap = OWACreateCalendarEventPayload.createItemSOAP(
            title: "T",
            agenda: "secret ]]> payload",
            location: "",
            start: referenceStart,
            end: referenceEnd,
            requiredAttendees: []
        )
        XCTAssertTrue(soap.contains("<![CDATA["))
        // В пределах CDATA не должно встречаться закрытие, кроме одного итогового `]]>`.
        let cdataRange = soap.range(of: "<![CDATA[")!
        let closeRange = soap.range(of: "]]></t:Body>")!
        let inside = String(soap[cdataRange.upperBound..<closeRange.lowerBound])
        XCTAssertFalse(inside.contains("]]>"), "raw ]]> inside CDATA would break XML parsing on the server")
    }

    // MARK: - Порядок Required → Optional (важно для схемы EWS)

    func testRequiredAttendeesAppearBeforeOptional() {
        let soap = OWACreateCalendarEventPayload.createItemSOAP(
            title: "T",
            agenda: "",
            location: "",
            start: referenceStart,
            end: referenceEnd,
            requiredAttendees: [attendee("req@x.com")],
            optionalAttendees: [attendee("opt@x.com")]
        )
        guard let req = soap.range(of: "<t:RequiredAttendees>"),
              let opt = soap.range(of: "<t:OptionalAttendees>") else {
            XCTFail("Expected both Required and Optional sections in SOAP")
            return
        }
        XCTAssertLessThan(req.lowerBound, opt.lowerBound, "EWS schema requires RequiredAttendees before OptionalAttendees")
    }

    func testOmitsOptionalAttendeesSectionWhenEmpty() {
        let soap = OWACreateCalendarEventPayload.createItemSOAP(
            title: "T",
            agenda: "",
            location: "",
            start: referenceStart,
            end: referenceEnd,
            requiredAttendees: [attendee("a@x.com")],
            optionalAttendees: []
        )
        XCTAssertFalse(soap.contains("<t:OptionalAttendees>"))
        XCTAssertTrue(soap.contains("<t:RequiredAttendees>"))
    }

    func testIncludesAllAttendeesInOrder() {
        let soap = OWACreateCalendarEventPayload.createItemSOAP(
            title: "T",
            agenda: "",
            location: "",
            start: referenceStart,
            end: referenceEnd,
            requiredAttendees: [attendee("alice@x.com"), attendee("bob@x.com")],
            optionalAttendees: [attendee("carol@x.com")]
        )
        let alice = soap.range(of: "alice@x.com")!
        let bob   = soap.range(of: "bob@x.com")!
        let carol = soap.range(of: "carol@x.com")!
        XCTAssertLessThan(alice.lowerBound, bob.lowerBound)
        XCTAssertLessThan(bob.lowerBound, carol.lowerBound)
    }

    // MARK: - Даты в UTC

    func testStartAndEndAreFormattedAsUTCISO8601WithTrailingZ() {
        let soap = OWACreateCalendarEventPayload.createItemSOAP(
            title: "T",
            agenda: "",
            location: "",
            start: referenceStart,
            end: referenceEnd,
            requiredAttendees: []
        )
        // 1_700_000_000 == 2023-11-14T22:13:20Z
        XCTAssertTrue(soap.contains("<t:Start>2023-11-14T22:13:20Z</t:Start>"))
        XCTAssertTrue(soap.contains("<t:End>2023-11-14T22:43:20Z</t:End>"))
    }

    func testDateFormatterDefaultIgnoresLocalTimezone() {
        // Foundation иногда канонизирует identifier UTC → GMT. Важна семантика: 0 offset + POSIX-локаль.
        let fmt = OWACreateCalendarEventPayload.ewsDateFormatter()
        XCTAssertEqual(fmt.timeZone.secondsFromGMT(), 0)
        XCTAssertEqual(fmt.locale.identifier, "en_US_POSIX")
    }

    // MARK: - Напоминание

    func testReminderDefaultsTo15Minutes() {
        let soap = OWACreateCalendarEventPayload.createItemSOAP(
            title: "T",
            agenda: "",
            location: "",
            start: referenceStart,
            end: referenceEnd,
            requiredAttendees: []
        )
        XCTAssertTrue(soap.contains("<t:IsReminderSet>true</t:IsReminderSet>"))
        XCTAssertTrue(soap.contains("<t:ReminderMinutesBeforeStart>15</t:ReminderMinutesBeforeStart>"))
    }

    // MARK: - Низкоуровневый escapeXML

    func testEscapeXMLHandlesAllSpecialCharacters() {
        XCTAssertEqual(OWACreateCalendarEventPayload.escapeXML("&"),  "&amp;")
        XCTAssertEqual(OWACreateCalendarEventPayload.escapeXML("<"),  "&lt;")
        XCTAssertEqual(OWACreateCalendarEventPayload.escapeXML(">"),  "&gt;")
        XCTAssertEqual(OWACreateCalendarEventPayload.escapeXML("\""), "&quot;")
        // & должно эскейпиться первым, иначе &lt; превратится в &amp;lt;
        XCTAssertEqual(OWACreateCalendarEventPayload.escapeXML("<&>"), "&lt;&amp;&gt;")
    }
}
