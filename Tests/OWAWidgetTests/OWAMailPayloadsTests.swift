import XCTest
@testable import OWAWidget

final class OWAMailPayloadsTests: XCTestCase {
    private let zone = "Russian Standard Time"

    private func roundTrip(_ payload: [String: Any]) throws -> [String: Any] {
        let text = OWAClient.serializeJSONTypeFirst(payload)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func body(_ payload: [String: Any]) throws -> [String: Any] {
        try XCTUnwrap(try roundTrip(payload)["Body"] as? [String: Any])
    }

    func testTypeComesFirstInSerializedJSON() {
        let text = OWAClient.serializeJSONTypeFirst(OWAMailPayloads.getItem(MailItemRef(id: "I1", changeKey: "CK"), timeZoneID: zone))
        XCTAssertTrue(text.hasPrefix("{\"__type\":\"GetItemJsonRequest:#Exchange\""))
        XCTAssertTrue(text.contains("{\"__type\":\"ItemId:#Exchange\",\"ChangeKey\":\"CK\",\"Id\":\"I1\"}"))
    }

    func testFindConversationFirstPageAndSeek() throws {
        let first = try body(OWAMailPayloads.findConversation(
            folder: OWAMailPayloads.distinguishedFolderID(.inbox), cursor: .first, filter: .all, sentItems: false, timeZoneID: zone
        ))
        let paging = try XCTUnwrap(first["Paging"] as? [String: Any])
        XCTAssertEqual(paging["__type"] as? String, "IndexedPageView:#Exchange")
        XCTAssertEqual(paging["MaxEntriesReturned"] as? Int, 25)
        XCTAssertEqual(first["ShapeName"] as? String, "ConversationListView")
        XCTAssertEqual(first["ViewFilter"] as? String, "All")

        let next = try body(OWAMailPayloads.findConversation(
            folder: OWAMailPayloads.folderID("F1"), cursor: .after(instanceKey: "KEY"), filter: .unread, sentItems: true, timeZoneID: zone
        ))
        let seek = try XCTUnwrap(next["Paging"] as? [String: Any])
        XCTAssertEqual(seek["__type"] as? String, "SeekToConditionPageView:#Exchange")
        let condition = try XCTUnwrap((seek["Condition"] as? [String: Any])?["Item"] as? [String: Any])
        XCTAssertEqual((condition["Item"] as? [String: Any])?["FieldURI"] as? String, "ConversationInstanceKey")
        XCTAssertEqual(((condition["FieldURIOrConstant"] as? [String: Any])?["Item"] as? [String: Any])?["Value"] as? String, "KEY")
        XCTAssertEqual(next["ShapeName"] as? String, "ConversationSentItemsListView")
        XCTAssertEqual(next["ViewFilter"] as? String, "Unread")
    }

    func testReadingShapeHasNoScriptHooks() throws {
        let request = try body(OWAMailPayloads.getConversationItems(conversationID: "C1", foldersToIgnore: ["DEL"], timeZoneID: zone))
        let shape = try XCTUnwrap(request["ItemShape"] as? [String: Any])
        XCTAssertNil(shape["InlineImageUrlOnLoadTemplate"])
        XCTAssertNil(shape["InlineImageCustomDataTemplate"])
        XCTAssertEqual(shape["FilterHtmlContent"] as? Bool, true)
        XCTAssertEqual(shape["BlockExternalImagesIfSenderUntrusted"] as? Bool, true)
        XCTAssertEqual((request["FoldersToIgnore"] as? [[String: Any]])?.first?["Id"] as? String, "DEL")
    }

    func testUpdateItemNeverSendsReadReceipts() throws {
        for update in [MailItemUpdate.isRead(true), .isRead(false), .categories(["X"]), .flag(.flagged)] {
            let request = try body(OWAMailPayloads.updateItem(MailItemTarget(MailItemRef(id: "I1", changeKey: "CK"), kind: .note), update: update, timeZoneID: zone))
            XCTAssertEqual(request["SuppressReadReceipts"] as? Bool, true)
            XCTAssertEqual(request["MessageDisposition"] as? String, "SaveOnly")
        }
        let read = try body(OWAMailPayloads.updateItem(MailItemTarget(MailItemRef(id: "I1", changeKey: "CK"), kind: .note), update: .isRead(false), timeZoneID: zone))
        let change = try XCTUnwrap((read["ItemChanges"] as? [[String: Any]])?.first)
        let set = try XCTUnwrap((change["Updates"] as? [[String: Any]])?.first)
        XCTAssertEqual((set["Path"] as? [String: Any])?["FieldURI"] as? String, "IsRead")
        XCTAssertEqual((set["Item"] as? [String: Any])?["IsRead"] as? Bool, false)
        XCTAssertEqual((set["Item"] as? [String: Any])?["__type"] as? String, "Message:#Exchange")
    }

    /// A flag on a meeting response sent as a plain `Message` fails with `ErrorItemNotFound` ("ID
    /// type 9; actual type 12"), and OWA does not deserialize `MeetingResponseMessage` there:
    /// meeting messages go as the base `Item`, each change on its own inside one batch.
    func testUpdateItemNamesEachItemsOwnType() throws {
        let targets = [
            MailItemTarget(MailItemRef(id: "R", changeKey: nil), kind: .meetingResponse),
            MailItemTarget(MailItemRef(id: "Q", changeKey: nil), kind: .meetingRequest),
            MailItemTarget(MailItemRef(id: "X", changeKey: nil), kind: .meetingCancellation),
            MailItemTarget(MailItemRef(id: "N", changeKey: nil), kind: .note),
        ]
        let request = try body(OWAMailPayloads.updateItems(targets, update: .flag(.flagged), timeZoneID: zone))
        let types = try XCTUnwrap(request["ItemChanges"] as? [[String: Any]]).map { change in
            (((change["Updates"] as? [[String: Any]])?.first?["Item"]) as? [String: Any])?["__type"] as? String
        }
        XCTAssertEqual(types, ["Item:#Exchange", "Item:#Exchange", "Item:#Exchange", "Message:#Exchange"])
        let item = try XCTUnwrap((((request["ItemChanges"] as? [[String: Any]])?.first?["Updates"] as? [[String: Any]])?.first?["Item"]) as? [String: Any])
        XCTAssertEqual((item["Flag"] as? [String: Any])?["FlagStatus"] as? String, "Flagged")
    }

    /// `IsRead` as `Message` is what marked invitations read before; any other name there broke it.
    func testReadStateIsAlwaysAMessage() throws {
        for kind in [MailItemKind.meetingRequest, .meetingResponse, .meetingCancellation, .note] {
            let request = try body(OWAMailPayloads.updateItem(MailItemTarget(MailItemRef(id: "I", changeKey: nil), kind: kind), update: .isRead(true), timeZoneID: zone))
            let item = (((request["ItemChanges"] as? [[String: Any]])?.first?["Updates"] as? [[String: Any]])?.first?["Item"]) as? [String: Any]
            XCTAssertEqual(item?["__type"] as? String, "Message:#Exchange", "\(kind)")
        }
    }

    func testDateRestrictionUpperBoundIsTheNextDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Moscow")!
        let from = calendar.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 15))!
        let to = calendar.date(from: DateComponents(year: 2026, month: 10, day: 17, hour: 9))!
        let restriction = try XCTUnwrap(OWAMailPayloads.dateRestriction(from: from, to: to, calendar: calendar))
        let text = OWAClient.serializeJSONTypeFirst(restriction)
        XCTAssertTrue(text.contains("\"IsLessThanOrEqualTo:#Exchange\""))
        XCTAssertTrue(text.contains("\"Value\":\"2026-10-18\""))
        XCTAssertTrue(text.contains("\"Value\":\"2026-10-12\""))
        XCTAssertNil(OWAMailPayloads.dateRestriction(from: nil, to: nil, calendar: calendar))
    }

    func testSearchRefinersAndOffsets() throws {
        var query = MailSearchQuery(text: " release ", scope: .distinguished(.inbox))
        query.from = ["g.miller@example.com"]
        query.hasAttachments = true
        XCTAssertEqual(OWAMailPayloads.refinerQueries(for: query), [
            "ShallowRefiner::SearchScope:from:\"g.miller@example.com\"",
            "ShallowRefiner::SearchScope:hasattachment:true",
        ])
        let first = try body(OWAMailPayloads.executeSearch(sessionID: "S", query: query, offset: 0, count: 25, calendar: .current, timeZoneID: zone))
        XCTAssertEqual(first["Query"] as? String, "release")
        XCTAssertEqual(first["RetrieveRefiners"] as? Bool, true)
        XCTAssertEqual(first["MaxResultsCountHint"] as? Int, 250)
        let scope = try XCTUnwrap((first["SearchScope"] as? [[String: Any]])?.first?["FolderScope"] as? [String: Any])
        XCTAssertEqual((scope["BaseFolderId"] as? [String: Any])?["Id"] as? String, "inbox")
        let next = try body(OWAMailPayloads.executeSearch(sessionID: "S", query: MailSearchQuery(text: "x"), offset: 25, count: 50, calendar: .current, timeZoneID: zone))
        XCTAssertEqual(next["RetrieveRefiners"] as? Bool, false)
        XCTAssertTrue(next["SearchRefiners"] is NSNull)
        XCTAssertTrue(next["SearchRestrictions"] is NSNull)
    }

    // MARK: - EWS

    func testReplySOAPReferencesOriginalAndEscapes() {
        let soap = OWAMailPayloads.createMessageSOAP(MailOutgoing(
            kind: .replyAll,
            reference: MailItemRef(id: "ID&1", changeKey: "CK\"2"),
            to: ["a@example.com"],
            cc: [],
            subject: "",
            body: "Hi <team>\n\nThanks & bye ]]>"
        ))
        XCTAssertTrue(soap.contains(#"MessageDisposition="SendAndSaveCopy""#))
        XCTAssertTrue(soap.contains(#"<t:DistinguishedFolderId Id="sentitems"/>"#))
        XCTAssertTrue(soap.contains("<t:ReplyAllToItem>"))
        XCTAssertTrue(soap.contains(#"<t:ReferenceItemId Id="ID&amp;1" ChangeKey="CK&quot;2"/>"#))
        XCTAssertTrue(soap.contains("<div>Hi &lt;team&gt;</div><div><br></div><div>Thanks &amp; bye ]]&gt;</div>"))
        XCTAssertFalse(soap.contains("<t:Subject>"), "an empty subject keeps the server's RE:")
        // Schema order: recipients before the reference, the reference before the new body.
        let to = soap.range(of: "<t:ToRecipients>")!.lowerBound
        let ref = soap.range(of: "<t:ReferenceItemId")!.lowerBound
        let body = soap.range(of: "<t:NewBodyContent")!.lowerBound
        XCTAssertTrue(to < ref && ref < body)
    }

    func testNewDraftIsSavedNotSent() {
        let soap = OWAMailPayloads.createMessageSOAP(MailOutgoing(
            kind: .new, reference: nil, to: ["a@example.com"], cc: ["b@example.com"], subject: "Plan <v2>", body: "x", send: false
        ))
        XCTAssertTrue(soap.contains(#"MessageDisposition="SaveOnly""#))
        XCTAssertTrue(soap.contains(#"<t:DistinguishedFolderId Id="drafts"/>"#))
        XCTAssertTrue(soap.contains("<t:Message><t:Subject>Plan &lt;v2&gt;</t:Subject>"))
        XCTAssertTrue(soap.contains("<t:CcRecipients><t:Mailbox><t:EmailAddress>b@example.com</t:EmailAddress></t:Mailbox></t:CcRecipients>"))
    }
}
