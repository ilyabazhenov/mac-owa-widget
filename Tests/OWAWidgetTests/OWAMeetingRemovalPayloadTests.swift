import XCTest
@testable import OWAWidget

final class OWAMeetingRemovalPayloadTests: XCTestCase {
    func testOrganizerCancellationSendsCancelCalendarItemWithTheNote() {
        let soap = OWAMeetingRemovalPayload.soap(itemId: "AAMk=", changeKey: "CK", mode: .cancelForAttendees, message: "Переносим <на завтра> & позже")

        XCTAssertEqual(OWAMeetingRemovalPayload.action(for: .cancelForAttendees), "CreateItem")
        XCTAssertTrue(soap.contains(#"<m:CreateItem MessageDisposition="SendAndSaveCopy">"#))
        XCTAssertTrue(soap.contains(#"<t:CancelCalendarItem><t:ReferenceItemId Id="AAMk=" ChangeKey="CK"/><t:NewBodyContent BodyType="Text">Переносим &lt;на завтра&gt; &amp; позже</t:NewBodyContent></t:CancelCalendarItem>"#))
    }

    func testDeclinePutsTheBodyBeforeTheReference() {
        let soap = OWAMeetingRemovalPayload.soap(itemId: "id", changeKey: nil, mode: .decline, message: "Не смогу")

        XCTAssertTrue(soap.contains(#"<t:DeclineItem><t:Body BodyType="Text">Не смогу</t:Body><t:ReferenceItemId Id="id"/></t:DeclineItem>"#))
    }

    func testEmptyNoteSendsNoBody() {
        for mode in [MeetingRemovalMode.cancelForAttendees, .decline] {
            let soap = OWAMeetingRemovalPayload.soap(itemId: "id", changeKey: "ck", mode: mode, message: "  \n")
            XCTAssertFalse(soap.contains("NewBodyContent"), "\(mode)")
            XCTAssertFalse(soap.contains("<t:Body"), "\(mode)")
        }
    }

    func testSilentDeleteMovesToDeletedItemsAndTellsNobody() {
        let soap = OWAMeetingRemovalPayload.soap(itemId: "id", changeKey: "ck", mode: .deleteSilently, message: "ignored")

        XCTAssertEqual(OWAMeetingRemovalPayload.action(for: .deleteSilently), "DeleteItem")
        XCTAssertTrue(soap.contains(#"DeleteType="MoveToDeletedItems""#))
        XCTAssertTrue(soap.contains(#"SendMeetingCancellations="SendToNone""#))
        XCTAssertTrue(soap.contains(#"<t:ItemId Id="id" ChangeKey="ck"/>"#))
        XCTAssertFalse(soap.contains("HardDelete"))
        XCTAssertFalse(soap.contains("ignored"))
    }

    func testServerAuthoredIdsCannotBreakOutOfTheAttribute() {
        for mode in [MeetingRemovalMode.cancelForAttendees, .decline, .deleteSilently] {
            let soap = OWAMeetingRemovalPayload.soap(itemId: #"x"/><t:Evil/>"#, changeKey: #"k"<"#, mode: mode, message: "")
            XCTAssertFalse(soap.contains("<t:Evil/>"), "\(mode)")
            XCTAssertTrue(soap.contains(#"Id="x&quot;/&gt;&lt;t:Evil/&gt;""#), "\(mode)")
            XCTAssertTrue(soap.contains(#"ChangeKey="k&quot;&lt;""#), "\(mode)")
        }
    }
}
