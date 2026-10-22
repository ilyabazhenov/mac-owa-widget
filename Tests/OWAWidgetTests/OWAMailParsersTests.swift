import XCTest
@testable import OWAWidget

/// Synthetic responses shaped like the OWA HAR captures (Exchange 15.2.2562): fictional people,
/// example.com addresses, made-up ids. Real captures never go into the repository.
final class OWAMailParsersTests: XCTestCase {

    private func data(_ json: String) -> Data { Data(json.utf8) }

    // MARK: - Conversations

    private let conversationsJSON = """
    {"Header":{"ServerVersionInfo":{"MajorVersion":15}},
     "Body":{"ResponseCode":"NoError","ResponseClass":"Success",
      "Conversations":[
        {"ConversationId":{"Id":"AAQkTEST-CONV-1"},"ConversationTopic":"Release 1.3: final checklist",
         "UniqueSenders":["Grace Miller"],"LastDeliveryTime":"2026-10-16T20:07:52+03:00",
         "HasAttachments":true,"MessageCount":3,"UnreadCount":1,"Importance":"High",
         "ItemIds":[{"__type":"ItemId:#Exchange","ChangeKey":"CQAAAA==","Id":"AAMkTEST-ITEM-1"}],
         "InstanceKey":"AQAAA+TESTKEY1","Preview":"Folks,\\r\\nhere is everything left","HasIrm":false,
         "Categories":["Release"],"FlagStatus":"Flagged"},
        {"ConversationId":{"Id":"AAQkTEST-CONV-2"},"ConversationTopic":"Build #205","UniqueSenders":["Jenkins"],
         "LastDeliveryTime":"2026-10-15T10:00:00+03:00","MessageCount":1,"UnreadCount":0,
         "ItemIds":[{"Id":"AAMkTEST-ITEM-2"}],"InstanceKey":"AQAAA+TESTKEY2"},
        {"ConversationTopic":"no id: dropped"}
      ],
      "IndexedOffset":25,"TotalConversationsInView":4519}}
    """

    func testConversationPageParsesFieldsAndCursor() throws {
        let page = try OWAMailParsers.conversationPage(data(conversationsJSON), requested: 25)
        XCTAssertEqual(page.conversations.count, 2)
        XCTAssertEqual(page.totalInView, 4519)
        XCTAssertEqual(page.nextCursor, .after(instanceKey: "AQAAA+TESTKEY2"))

        let first = page.conversations[0]
        XCTAssertEqual(first.id, "AAQkTEST-CONV-1")
        XCTAssertEqual(first.topic, "Release 1.3: final checklist")
        XCTAssertEqual(first.senders, ["Grace Miller"])
        XCTAssertEqual(first.messageCount, 3)
        XCTAssertEqual(first.unreadCount, 1)
        XCTAssertTrue(first.isUnread)
        XCTAssertTrue(first.hasAttachments)
        XCTAssertEqual(first.importance, .high)
        XCTAssertEqual(first.itemRefs, [MailItemRef(id: "AAMkTEST-ITEM-1", changeKey: "CQAAAA==")])
        XCTAssertEqual(first.preview, "Folks, here is everything left")
        XCTAssertEqual(first.categories, ["Release"])
        XCTAssertTrue(first.isFlagged)
        XCTAssertEqual(first.lastDelivery, ISO8601DateFormatter().date(from: "2026-10-16T17:07:52Z"))
    }

    func testLastPageHasNoCursor() throws {
        let json = """
        {"Body":{"ResponseCode":"NoError","Conversations":[{"ConversationId":{"Id":"C1"},"InstanceKey":"K1"}],
         "IndexedOffset":3,"TotalConversationsInView":3}}
        """
        XCTAssertNil(try OWAMailParsers.conversationPage(data(json), requested: 25).nextCursor)
    }

    func testErrorResponseThrows() {
        let json = #"{"Body":{"ResponseCode":"ErrorAccessDenied","ResponseClass":"Error"}}"#
        XCTAssertThrowsError(try OWAMailParsers.conversationPage(data(json), requested: 25)) { error in
            XCTAssertEqual(error as? MailError, .serverError("ErrorAccessDenied"))
        }
    }

    func testItemNotFoundMapsToNotFound() {
        let json = #"{"Body":{"ResponseMessages":{"Items":[{"ResponseCode":"ErrorItemNotFound","ResponseClass":"Error"}]}}}"#
        XCTAssertThrowsError(try OWAMailParsers.messages(data(json))) { error in
            XCTAssertEqual(error as? MailError, .notFound)
        }
    }

    func testNonJSONThrows() {
        XCTAssertThrowsError(try OWAMailParsers.conversationPage(data("<html>logon</html>"), requested: 25))
    }

    // MARK: - Thread

    private let threadJSON = """
    {"Body":{"ResponseMessages":{"Items":[{"__type":"GetConversationItemsResponseMessage:#Exchange",
     "ResponseCode":"NoError","ResponseClass":"Success",
     "Conversation":{"ConversationId":{"Id":"AAQkTEST-CONV-1"},"SyncState":"AQ==","TotalConversationNodesCount":2,
      "ConversationNodes":[
       {"Items":[{"__type":"Message:#Exchange","ItemId":{"Id":"ITEM-OLD","ChangeKey":"CK-OLD"},
         "ItemClass":"IPM.Note","Subject":"Release 1.3","DateTimeReceived":"2026-10-15T09:00:00+03:00",
         "From":{"Mailbox":{"Name":"Noah Bennett","EmailAddress":"n.bennett@example.com","RoutingType":"SMTP"}},
         "IsRead":true,"UniqueBody":{"BodyType":"HTML","Value":"<div>Old</div>"}}]},
       {"Items":[{"__type":"Message:#Exchange","ItemId":{"Id":"ITEM-NEW","ChangeKey":"CK-NEW"},
         "ParentFolderId":{"Id":"FOLDER-INBOX"},"ConversationId":{"Id":"AAQkTEST-CONV-1"},
         "ItemClass":"IPM.Note","Subject":"Release 1.3","Importance":"Normal",
         "DateTimeReceived":"2026-10-16T10:42:00+03:00","DateTimeSent":"2026-10-16T10:41:58+03:00",
         "From":{"Mailbox":{"Name":"Grace Miller","EmailAddress":"g.miller@example.com","RoutingType":"SMTP"}},
         "ToRecipients":[{"Name":"Alex Morgan","EmailAddress":"a.morgan@example.com","RoutingType":"SMTP"},
                         {"Name":"Legacy Person","EmailAddress":"/O=EXAMPLE/OU=EXCHANGE/CN=RECIPIENTS/CN=LEGACY","RoutingType":"EX"}],
         "CcRecipients":[{"Name":"Jack Morrison","EmailAddress":"j.morrison@example.com"}],
         "RecipientCounts":{"ToRecipientsCount":2,"CcRecipientsCount":7,"BccRecipientsCount":0},
         "IsRead":false,"HasAttachments":true,
         "Attachments":[
           {"__type":"FileAttachment:#Exchange","AttachmentId":{"Id":"ATT-1"},"ContentType":"application/octet-stream",
            "Name":"checklist.xlsx","Size":48000},
           {"__type":"FileAttachment:#Exchange","AttachmentId":{"Id":"ATT-2"},"ContentId":"image003.png@01DD",
            "ContentType":"image/png","IsInline":true,"Name":"image003.png","Size":4786},
           {"__type":"ItemAttachment:#Exchange","AttachmentId":{"Id":"ATT-3"},"Name":"Forwarded","Size":9000}],
         "ResponseObjects":[{"__type":"ReplyToItem:#Exchange"},{"__type":"ReplyAllToItem:#Exchange"},{"__type":"ForwardItem:#Exchange"}],
         "Flag":{"FlagStatus":"NotFlagged"},"Categories":["Release"],
         "UniqueBody":{"BodyType":"HTML","Value":"<div class=\\"rps_owaw\\">Hi all</div>"},
         "InternetMessageId":"<abc@example.com>"}]}
      ]}}]}}}
    """

    func testThreadParsesMessagesNewestFirst() throws {
        let thread = try OWAMailParsers.thread(data(threadJSON), conversationID: "fallback")
        XCTAssertEqual(thread.id, "AAQkTEST-CONV-1")
        XCTAssertEqual(thread.totalMessageCount, 2)
        XCTAssertEqual(thread.messages.map(\.id), ["ITEM-NEW", "ITEM-OLD"])

        let message = thread.messages[0]
        XCTAssertEqual(message.ref, MailItemRef(id: "ITEM-NEW", changeKey: "CK-NEW"))
        XCTAssertEqual(message.kind, .note)
        XCTAssertEqual(message.from, MailAddress(name: "Grace Miller", email: "g.miller@example.com"))
        XCTAssertEqual(message.to.map(\.email), ["a.morgan@example.com", nil], "an EX legacy DN is no address")
        XCTAssertEqual(message.cc.map(\.displayName), ["Jack Morrison"])
        XCTAssertEqual(message.hiddenRecipientCount, 6)
        XCTAssertFalse(message.isRead)
        XCTAssertEqual(message.bodyHTML, "<div class=\"rps_owaw\">Hi all</div>")
        XCTAssertEqual(message.attachments.count, 3)
        XCTAssertEqual(message.visibleAttachments.map(\.name), ["checklist.xlsx", "Forwarded"])
        XCTAssertTrue(message.attachments[2].isItemAttachment)
        XCTAssertEqual(message.attachments[1].contentID, "image003.png@01DD")
        XCTAssertEqual(message.actions, [.reply, .replyAll, .forward])
        XCTAssertFalse(message.isFlagged)
        XCTAssertEqual(message.parentFolderID, "FOLDER-INBOX")
    }

    func testSpecialItemKinds() {
        XCTAssertEqual(MailItemKind(itemClass: "IPM.Note.EnterpriseVault.Shortcut"), .archived)
        XCTAssertEqual(MailItemKind(itemClass: "IPM.Note", hasIrm: true), .protected)
        XCTAssertEqual(MailItemKind(itemClass: "IPM.Note.SMIME"), .protected)
        XCTAssertEqual(MailItemKind(itemClass: "IPM.Schedule.Meeting.Request"), .meetingRequest)
        XCTAssertEqual(MailItemKind(itemClass: "IPM.Schedule.Meeting.Canceled"), .meetingCancellation)
        XCTAssertEqual(MailItemKind(itemClass: "IPM.Schedule.Meeting.Resp.Pos"), .meetingResponse)
        XCTAssertEqual(MailItemKind(itemClass: "IPM.Note.Rules.OofTemplate.Microsoft"), .note)
        XCTAssertFalse(MailItemKind.archived.hasReadableBody)
    }

    func testPlainTextBodyIsEscaped() throws {
        let json = """
        {"Body":{"ResponseMessages":{"Items":[{"ResponseCode":"NoError","Items":[
          {"ItemId":{"Id":"I1"},"ItemClass":"IPM.Note","NormalizedBody":{"BodyType":"Text","Value":"a < b & <script>"}}]}]}}}
        """
        let message = try XCTUnwrap(OWAMailParsers.messages(data(json)).first)
        XCTAssertEqual(message.bodyHTML, "<div style=\"white-space: pre-wrap\">a &lt; b &amp; &lt;script&gt;</div>")
    }

    func testMeetingRequestCarriesTime() throws {
        let json = """
        {"Body":{"ResponseMessages":{"Items":[{"ResponseCode":"NoError","Items":[
          {"ItemId":{"Id":"I1"},"ItemClass":"IPM.Schedule.Meeting.Request","Start":"2026-10-20T11:00:00+03:00",
           "End":"2026-10-20T12:00:00+03:00","Location":{"DisplayName":"Room 4"},
           "AssociatedCalendarItemId":{"Id":"CAL-1"},
           "ResponseObjects":[{"__type":"AcceptItem:#Exchange"},{"__type":"DeclineItem:#Exchange"}]}]}]}}}
        """
        let message = try XCTUnwrap(OWAMailParsers.messages(data(json)).first)
        XCTAssertEqual(message.kind, .meetingRequest)
        XCTAssertEqual(message.meeting?.location, "Room 4")
        XCTAssertEqual(message.meeting?.associatedCalendarItemID, "CAL-1")
        XCTAssertEqual(message.actions, [.acceptMeeting, .declineMeeting])
    }

    func testMeetingResponseCarriesAnswer() throws {
        let json = """
        {"Body":{"ResponseMessages":{"Items":[{"ResponseCode":"NoError","Items":[
          {"ItemId":{"Id":"I1"},"ItemClass":"IPM.Schedule.Meeting.Resp.Pos","Start":"2026-10-21T12:30:00+03:00"},
          {"ItemId":{"Id":"I2"},"ItemClass":"IPM.Schedule.Meeting.Resp.Tent"},
          {"ItemId":{"Id":"I3"},"ItemClass":"IPM.Schedule.Meeting.Resp.Neg"},
          {"ItemId":{"Id":"I4"},"ItemClass":"IPM.Schedule.Meeting.Request"}]}]}}}
        """
        let messages = try OWAMailParsers.messages(data(json))
        XCTAssertEqual(messages.map(\.meeting?.response), [.accepted, .tentative, .declined, nil])
        XCTAssertEqual(messages[0].kind, .meetingResponse)
    }

    @MainActor
    func testConversationMeetingResponse() {
        var summary = MailConversationSummary(
            id: "C1", topic: "Принято: Репетиция", senders: [], recipients: [], lastDelivery: nil, messageCount: 1,
            unreadCount: 0, hasAttachments: false, importance: .normal, preview: "", itemRefs: [], categories: [],
            isFlagged: false, isProtected: false, instanceKey: nil, parentFolderID: nil
        )
        summary.itemClasses = ["IPM.Schedule.Meeting.Resp.Pos"]
        XCTAssertEqual(summary.meetingResponse, .accepted)
        summary.itemClasses = ["IPM.Schedule.Meeting.Resp.Pos", "IPM.Schedule.Meeting.Resp.Neg"]
        XCTAssertNil(summary.meetingResponse, "answers that disagree carry no single tag")
        summary.itemClasses = ["IPM.Note"]
        XCTAssertNil(summary.meetingResponse)
        XCTAssertEqual(MailPresentation.strippingMeetingPrefix("Принято: Репетиция"), "Репетиция")
        XCTAssertEqual(MailPresentation.strippingMeetingPrefix("accepted: Demo"), "Demo")
        XCTAssertEqual(MailPresentation.strippingMeetingPrefix("Репетиция"), "Репетиция")
        XCTAssertEqual(MailPresentation.strippingMeetingPrefix("Отменено: Репетиция"), "Репетиция")
        summary.itemClasses = ["IPM.Schedule.Meeting.Request", "IPM.Schedule.Meeting.Canceled"]
        XCTAssertEqual(summary.meetingStatus, .cancelled, "a cancellation outweighs the invitation")
        summary.itemClasses = ["IPM.Schedule.Meeting.Resp.Tent"]
        XCTAssertEqual(summary.meetingStatus, .response(.tentative))
    }

    func testForwardedInvitationKeepsActualSender() throws {
        let json = """
        {"Body":{"ResponseMessages":{"Items":[{"ResponseCode":"NoError","Items":[
          {"ItemId":{"Id":"I1"},"ItemClass":"IPM.Schedule.Meeting.Request",
           "From":{"Mailbox":{"Name":"Organizer","EmailAddress":"organizer@example.com","RoutingType":"SMTP"}},
           "Sender":{"Mailbox":{"Name":"Forwarder","EmailAddress":"forwarder@example.com","RoutingType":"SMTP"}}},
          {"ItemId":{"Id":"I2"},"ItemClass":"IPM.Note",
           "From":{"Mailbox":{"Name":"Grace","EmailAddress":"G@example.com","RoutingType":"SMTP"}},
           "Sender":{"Mailbox":{"Name":"Grace Miller","EmailAddress":"g@example.com","RoutingType":"SMTP"}}}]}]}}}
        """
        let messages = try OWAMailParsers.messages(data(json))
        XCTAssertEqual(messages[0].from?.displayName, "Organizer")
        XCTAssertEqual(messages[0].sender, MailAddress(name: "Forwarder", email: "forwarder@example.com"))
        XCTAssertNil(messages[1].sender, "the same mailbox is no delegate")
    }

    // MARK: - Folders

    func testFoldersFromGetFolder() throws {
        let json = """
        {"Body":{"ResponseMessages":{"Items":[{"__type":"FolderInfoResponseMessage:#Exchange","ResponseCode":"NoError",
         "Folders":[{"__type":"Folder:#Exchange","FolderId":{"Id":"F-INBOX","ChangeKey":"AQ"},"TotalCount":6512,"UnreadCount":443}]}]}}}
        """
        let folders = OWAMailParsers.folders(in: try OWAMailParsers.json(data(json)))
        XCTAssertEqual(folders.count, 1)
        XCTAssertEqual(folders[0].id, "F-INBOX")
        XCTAssertEqual(folders[0].unreadCount, 443)
        XCTAssertEqual(folders[0].totalCount, 6512)
    }

    func testFoldersFromSessionDataSkipNonMail() throws {
        let json = """
        {"owaUserConfig":{},"findFolders":{"Body":{"ResponseMessages":{"Items":[{"RootFolder":{"Folders":[
          {"__type":"Folder:#Exchange","FolderId":{"Id":"F-INBOX"},"DisplayName":"Inbox","DistinguishedFolderId":"inbox",
           "FolderClass":"IPF.Note","UnreadCount":12,"TotalCount":100,"ChildFolderCount":1},
          {"__type":"Folder:#Exchange","FolderId":{"Id":"F-JIRA"},"DisplayName":"Jira","FolderClass":"IPF.Note",
           "ParentFolderId":{"Id":"F-INBOX"},"UnreadCount":4},
          {"__type":"CalendarFolder:#Exchange","FolderId":{"Id":"F-CAL"},"DisplayName":"Calendar","FolderClass":"IPF.Appointment"},
          {"__type":"ContactsFolder:#Exchange","FolderId":{"Id":"F-CON"},"DisplayName":"Contacts"},
          {"__type":"Folder:#Exchange","FolderId":{"Id":"F-RSS"},"DisplayName":"RSS","FolderClass":"IPF.Note.OutlookHomepage"}
        ]}}]}}}}
        """
        let folders = OWAMailParsers.folders(in: try JSONSerialization.jsonObject(with: data(json)))
        XCTAssertEqual(Set(folders.map(\.id)), ["F-INBOX", "F-JIRA"])
        XCTAssertTrue(folders.contains { $0.id == "F-INBOX" && $0.distinguished == .inbox && $0.unreadCount == 12 })
        XCTAssertTrue(folders.contains { $0.id == "F-JIRA" && $0.parentID == "F-INBOX" })
        XCTAssertFalse(folders.contains { $0.id == "F-CAL" || $0.id == "F-CON" })
    }

    // MARK: - FindItem

    func testItemPage() throws {
        let json = """
        {"Body":{"ResponseMessages":{"Items":[{"ResponseCode":"NoError","RootFolder":{"IncludesLastItemInRange":false,
         "TotalItemsInView":30497,"Items":[
          {"ItemId":{"Id":"I1","ChangeKey":"C1"},"ConversationId":{"Id":"CV1"},"Subject":"Hello","ItemClass":"IPM.Schedule.Meeting.Resp.Pos",
           "From":{"Mailbox":{"Name":"Grace Miller","EmailAddress":"g.miller@example.com"}},"DisplayTo":"Alex Morgan",
           "DateTimeReceived":"2026-10-16T10:00:00+03:00","IsRead":false,"HasAttachments":true,"InstanceKey":"K1","Preview":"Hi"}]}}]}}}
        """
        let page = try OWAMailParsers.itemPage(data(json))
        XCTAssertEqual(page.items.count, 1)
        XCTAssertEqual(page.items[0].from?.email, "g.miller@example.com")
        XCTAssertEqual(page.items[0].kind, .meetingResponse, "mark-all-read changes it as one")
        XCTAssertEqual(page.totalInView, 30497)
        XCTAssertEqual(page.nextCursor, .after(instanceKey: "K1"))
    }

    func testItemPageRowCarriesWhatAConversationRowShows() throws {
        let json = """
        {"Body":{"ResponseMessages":{"Items":[{"ResponseCode":"NoError","RootFolder":{"IncludesLastItemInRange":true,
         "TotalItemsInView":2,"Items":[
          {"ItemId":{"Id":"I1","ChangeKey":"C1"},"ConversationId":{"Id":"CV1"},"ParentFolderId":{"Id":"INBOX"},"Subject":"Release",
           "ItemClass":"IPM.Note","From":{"Mailbox":{"Name":"Grace Miller","EmailAddress":"g.miller@example.com"}},
           "DisplayTo":"Alex Morgan; Sam Lee","DateTimeReceived":"2026-10-16T10:00:00+03:00","IsRead":false,
           "Categories":["Red"],"Flag":{"FlagStatus":"Flagged"},"Importance":"High",
           "Preview":"[EXTERNAL] Ship it","InstanceKey":"K1"},
          {"ItemId":{"Id":"I2"},"ConversationId":{"Id":"CV1"},"Subject":"RE: Release","IsRead":true,"InstanceKey":"K2"}]}}]}}}
        """
        let page = try OWAMailParsers.itemPage(data(json))
        XCTAssertNil(page.nextCursor, "the last item in range ends the folder")
        let rows = page.items.map(\.asListRow)
        XCTAssertEqual(rows.map(\.id), ["I1", "I2"], "two messages of one conversation are two rows")
        let row = rows[0]
        XCTAssertTrue(row.isSingleMessage)
        XCTAssertEqual(row.conversationKey, "CV1")
        XCTAssertEqual(row.itemRefs, [MailItemRef(id: "I1", changeKey: "C1")])
        XCTAssertEqual(row.topic, "Release")
        XCTAssertEqual(row.senders, ["Grace Miller"])
        XCTAssertEqual(row.senderEmail, "g.miller@example.com")
        XCTAssertEqual(row.recipients, ["Alex Morgan", "Sam Lee"])
        XCTAssertEqual(row.unreadCount, 1)
        XCTAssertEqual(row.messageCount, 1)
        XCTAssertEqual(row.categories, ["Red"])
        XCTAssertTrue(row.isFlagged)
        XCTAssertEqual(row.importance, .high)
        XCTAssertEqual(row.parentFolderID, "INBOX")
        XCTAssertEqual(row.preview, "Ship it")
        XCTAssertTrue(row.hasExternalBanner)
        XCTAssertEqual(row.uniformItemKind, .note)
        XCTAssertFalse(rows[1].isUnread)
        XCTAssertTrue(row.with(unreadCount: 0).isSingleMessage, "a changed row stays a message")
    }

    func testSearchForMessagesListsEachMessage() throws {
        let json = """
        {"Body":{"ResponseCode":"NoError","SearchResults":{"Conversations":null,"Items":[
          {"ItemId":{"Id":"I1"},"ConversationId":{"Id":"CV1"},"ParentFolderId":{"Id":"F1"},"Subject":"Release","IsRead":false},
          {"ItemId":{"Id":"I2"},"ConversationId":{"Id":"CV1"},"ParentFolderId":{"Id":"F1"},"Subject":"RE: Release","IsRead":true}],
         "MoreResultsAvailable":false,"SearchRefiners":[],"SearchTerms":["release"]}}}
        """
        let page = try OWAMailParsers.searchPage(data(json), offset: 0)
        XCTAssertEqual(page.conversations.map(\.id), ["I1", "I2"])
        XCTAssertTrue(page.conversations.allSatisfy(\.isSingleMessage))
        XCTAssertEqual(page.conversations.first?.parentFolderID, "F1")
    }

    // MARK: - Search

    func testEmptySearchIsNullNotArray() throws {
        let json = """
        {"Body":{"ResponseCode":"NoError","SearchResults":{"Conversations":null,"MoreResultsAvailable":false,
         "SearchRefiners":[],"SearchResultsCount":0,"SearchTerms":["release"],"TotalResultsCount":0}}}
        """
        let page = try OWAMailParsers.searchPage(data(json), offset: 0)
        XCTAssertTrue(page.conversations.isEmpty)
        XCTAssertFalse(page.moreAvailable)
        XCTAssertEqual(page.searchTerms, ["release"])
    }

    func testSearchRefiners() throws {
        let json = """
        {"Body":{"ResponseCode":"NoError","SearchResults":{
         "Conversations":[{"ConversationId":{"Id":"C1"},"ConversationTopic":"Release","ParentFolderId":{"Id":"F1"}}],
         "MoreResultsAvailable":true,"SearchRefiners":[
          {"__type":"PeopleRefinerType:#Exchange","Refiner":{"RefinerQuery":"ShallowRefiner::SearchScope:from:\\"g.miller@example.com\\""},
           "ResultCount":15,"DisplayName":"Grace Miller","SmtpAddress":"g.miller@example.com"},
          {"__type":"AttachmentRefinerType:#Exchange","Refiner":{"RefinerQuery":"ShallowRefiner::SearchScope:hasattachment:false"},
           "ResultCount":31,"HasAttachment":false},
          {"__type":"FolderRefinerType:#Exchange","Refiner":{"RefinerQuery":"ShallowRefiner::SearchScope:folderid:0000ABCD"},
           "ResultCount":31,"FolderId":{"Id":"F1"}}]}}}
        """
        let page = try OWAMailParsers.searchPage(data(json), offset: 0)
        XCTAssertEqual(page.conversations.first?.parentFolderID, "F1")
        XCTAssertTrue(page.moreAvailable)
        XCTAssertEqual(page.refiners, [
            .sender(name: "Grace Miller", email: "g.miller@example.com", count: 15),
            .attachments(has: false, count: 31),
            .folder(refinerID: "0000ABCD", folderID: "F1", count: 31),
        ])
    }

    // MARK: - Updates

    func testUpdatedRefs() throws {
        let json = """
        {"Body":{"ResponseMessages":{"Items":[{"__type":"UpdateItemResponseMessage:#Exchange","ResponseCode":"NoError",
         "Items":[{"__type":"Message:#Exchange","ItemId":{"ChangeKey":"CK2","Id":"I1"}}],"ConflictResults":{"Count":0}}]}}}
        """
        XCTAssertEqual(try OWAMailParsers.updatedRefs(data(json)), [MailItemRef(id: "I1", changeKey: "CK2")])
    }

    func testCreatedItemRefFromSOAP() {
        let soap = #"<m:CreateItemResponseMessage ResponseClass="Success"><m:ResponseCode>NoError</m:ResponseCode><m:Items><t:Message><t:ItemId Id="DRAFT-1" ChangeKey="CK"/></t:Message></m:Items>"#
        XCTAssertEqual(OWAMailParsers.createdItemRef(fromSOAP: soap), MailItemRef(id: "DRAFT-1", changeKey: "CK"))
        XCTAssertNil(OWAMailParsers.createdItemRef(fromSOAP: "<m:Items/>"))
    }

    func testDateWithoutOffsetUsesFallbackZone() {
        let zone = TimeZone(identifier: "Europe/Moscow")!
        XCTAssertEqual(
            OWAMailParsers.date("2026-10-17T00:04:49", fallbackZone: zone),
            ISO8601DateFormatter().date(from: "2026-10-16T21:04:49Z")
        )
    }

    /// The folder fallback skips a folder the mailbox lacks, never a sign-in or connection error:
    /// swallowed, each one would mean another password attempt against AD.
    func testFolderFallbackSkipsOnlyFolderLevelErrors() {
        XCTAssertTrue(OWAClient.isFolderLevelError(MailError.notFound))
        XCTAssertTrue(OWAClient.isFolderLevelError(OWAError.httpError(400, "ErrorFolderNotFound")))
        XCTAssertFalse(OWAClient.isFolderLevelError(OWAError.authenticationFailed("rejected")))
        XCTAssertFalse(OWAClient.isFolderLevelError(OWAError.httpError(401, "")))
        XCTAssertFalse(OWAClient.isFolderLevelError(OWAError.httpError(440, "")))
        XCTAssertFalse(OWAClient.isFolderLevelError(OWAError.httpError(449, "")))
        XCTAssertFalse(OWAClient.isFolderLevelError(OWAError.httpError(503, "")))
        XCTAssertFalse(OWAClient.isFolderLevelError(MailError.blocked("paused")))
        XCTAssertFalse(OWAClient.isFolderLevelError(URLError(.notConnectedToInternet)))
    }
}
