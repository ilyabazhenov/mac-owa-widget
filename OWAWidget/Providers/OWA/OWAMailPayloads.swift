import Foundation

/// Request bodies for the mail actions of OWA's `service.svc`, reproduced from HAR captures of
/// Exchange 2019 (15.2.2562) OWA. Pure functions: no network, no actor state.
///
/// The dictionaries go through `OWAClient.serializeJSONTypeFirst`: .NET's JSON serializer needs
/// `__type` before any other property wherever the declared type is abstract.
enum OWAMailPayloads {
    /// OWA asks for this many recipients per message; `RecipientCounts` tells how many there were.
    static let maximumRecipientsToReturn = 20
    /// For reading back a draft before it is sent: every recipient, or the check means nothing.
    static let maximumRecipientsForReview = 1000
    /// The server cuts bodies past this size (bytes).
    static let maximumBodySize = 2_097_152
    /// One transparent pixel: the server swaps it in for every inline image it does not serve.
    static let blankInlineImage = "data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAEALAAAAAABAAEAAAIBTAA7"
    /// Scopes the server's CSS rewriting of a message body to our container.
    static let cssScopeClassName = "rps_owaw"
    static let pageSize = 25
    static let searchResultsCap = 250

    // MARK: - Common pieces

    static func header(version: String, timeZoneID: String) -> [String: Any] {
        [
            "__type": "JsonRequestHeaders:#Exchange",
            "RequestServerVersion": version,
            "TimeZoneContext": [
                "__type": "TimeZoneContext:#Exchange",
                "TimeZoneDefinition": ["__type": "TimeZoneDefinitionType:#Exchange", "Id": timeZoneID],
            ],
        ]
    }

    static func folderID(_ id: String) -> [String: Any] {
        ["__type": "FolderId:#Exchange", "Id": id]
    }

    static func distinguishedFolderID(_ folder: MailDistinguishedFolder) -> [String: Any] {
        ["__type": "DistinguishedFolderId:#Exchange", "Id": folder.rawValue]
    }

    static func folderReference(_ scope: MailSearchScope) -> [String: Any] {
        switch scope {
        case .mailbox: distinguishedFolderID(.msgfolderroot)
        case .distinguished(let folder): distinguishedFolderID(folder)
        case .folder(let id): folderID(id)
        }
    }

    static func itemID(_ ref: MailItemRef) -> [String: Any] {
        var value: [String: Any] = ["__type": "ItemId:#Exchange", "Id": ref.id]
        if let changeKey = ref.changeKey { value["ChangeKey"] = changeKey }
        return value
    }

    static func propertyURI(_ field: String) -> [String: Any] {
        ["__type": "PropertyUri:#Exchange", "FieldURI": field]
    }

    static func sort(_ fields: [String]) -> [[String: Any]] {
        fields.map { ["__type": "SortResults:#Exchange", "Order": "Descending", "Path": propertyURI($0)] }
    }

    /// The item shape OWA uses to read message bodies. The JavaScript hooks the browser passes
    /// (`InlineImageUrlOnLoadTemplate`, `InlineImageCustomDataTemplate`) are left out on purpose:
    /// the reader here runs no script.
    static func readingItemShape(forConversation: Bool, maximumRecipients: Int = maximumRecipientsToReturn) -> [String: Any] {
        var shape: [String: Any] = [
            "__type": "ItemResponseShape:#Exchange",
            "BaseShape": "IdOnly",
            "FilterHtmlContent": true,
            "BlockExternalImagesIfSenderUntrusted": true,
            "BlockContentFromUnknownSenders": false,
            "AddBlankTargetToLinks": true,
            "ClientSupportsIrm": true,
            "InlineImageUrlTemplate": blankInlineImage,
            "FilterInlineSafetyTips": true,
            "MaximumBodySize": maximumBodySize,
            "MaximumRecipientsToReturn": maximumRecipients,
            "CssScopeClassName": cssScopeClassName,
        ]
        if forConversation {
            shape["ExcludeBindForInlineAttachments"] = true
            shape["CalculateOnlyFirstBody"] = true
        }
        return shape
    }

    static func seekPaging(after instanceKey: String, keyField: String, count: Int) -> [String: Any] {
        [
            "__type": "SeekToConditionPageView:#Exchange",
            "BasePoint": "Beginning",
            "Condition": [
                "__type": "RestrictionType:#Exchange",
                "Item": [
                    "__type": "IsEqualTo:#Exchange",
                    "Item": propertyURI(keyField),
                    "FieldURIOrConstant": [
                        "__type": "FieldURIOrConstantType:#Exchange",
                        "Item": ["__type": "Constant:#Exchange", "Value": instanceKey],
                    ],
                ],
            ],
            "MaxEntriesReturned": count,
        ]
    }

    // MARK: - Folders

    static func getFolder(folders: [[String: Any]], withNames: Bool, timeZoneID: String) -> [String: Any] {
        var additional = [propertyURI("UnreadCount"), propertyURI("TotalCount")]
        if withNames {
            additional.append(propertyURI("DisplayName"))
            additional.append(propertyURI("ParentFolderId"))
            additional.append(propertyURI("ChildFolderCount"))
        }
        return [
            "__type": "GetFolderJsonRequest:#Exchange",
            "Header": header(version: "Exchange2013", timeZoneID: timeZoneID),
            "Body": [
                "__type": "GetFolderRequest:#Exchange",
                "FolderShape": [
                    "__type": "FolderResponseShape:#Exchange",
                    "BaseShape": "IdOnly",
                    "AdditionalProperties": additional,
                ],
                "FolderIds": folders,
                "ShapeName": NSNull(),
            ],
        ]
    }

    // MARK: - Lists

    static func findConversation(
        folder: [String: Any],
        cursor: MailListCursor,
        filter: MailListFilter,
        sentItems: Bool,
        count: Int = pageSize,
        timeZoneID: String
    ) -> [String: Any] {
        let paging: [String: Any]
        switch cursor {
        case .first:
            paging = [
                "__type": "IndexedPageView:#Exchange",
                "BasePoint": "Beginning",
                "Offset": 0,
                "MaxEntriesReturned": count,
            ]
        case .after(let key):
            paging = seekPaging(after: key, keyField: "ConversationInstanceKey", count: count)
        }
        return [
            "__type": "FindConversationJsonRequest:#Exchange",
            "Header": header(version: "V2016_02_03", timeZoneID: timeZoneID),
            "Body": [
                "__type": "FindConversationRequest:#Exchange",
                "ParentFolderId": ["__type": "TargetFolderId:#Exchange", "BaseFolderId": folder],
                "ConversationShape": ["__type": "ConversationResponseShape:#Exchange", "BaseShape": "IdOnly"],
                "ShapeName": sentItems ? "ConversationSentItemsListView" : "ConversationListView",
                "Paging": paging,
                "ViewFilter": filter.rawValue,
                "FocusedViewFilter": -1,
                "SortOrder": sort(["ConversationLastDeliveryOrRenewTime", "ConversationLastDeliveryTime"]),
            ],
        ]
    }

    static func findItem(
        folder: [String: Any],
        cursor: MailListCursor,
        filter: MailListFilter,
        count: Int = pageSize,
        timeZoneID: String
    ) -> [String: Any] {
        let paging: [String: Any]
        switch cursor {
        case .first:
            paging = [
                "__type": "IndexedPageView:#Exchange",
                "BasePoint": "Beginning",
                "Offset": 0,
                "MaxEntriesReturned": count,
            ]
        case .after(let key):
            paging = seekPaging(after: key, keyField: "InstanceKey", count: count)
        }
        return [
            "__type": "FindItemJsonRequest:#Exchange",
            "Header": header(version: "Exchange2016", timeZoneID: timeZoneID),
            "Body": [
                "__type": "FindItemRequest:#Exchange",
                "ItemShape": ["__type": "ItemResponseShape:#Exchange", "BaseShape": "IdOnly"],
                "ParentFolderIds": [folder],
                "Traversal": "Shallow",
                "Paging": paging,
                "ViewFilter": filter.rawValue,
                "IsWarmUpSearch": false,
                "FocusedViewFilter": -1,
                "Grouping": NSNull(),
                "ShapeName": "MailListItem",
                "SortOrder": sort(["ReceivedOrRenewTime", "DateTimeReceived"]),
            ],
        ]
    }

    // MARK: - Reading

    static func getConversationItems(
        conversationID: String,
        foldersToIgnore: [String],
        maxItems: Int = 20,
        timeZoneID: String
    ) -> [String: Any] {
        [
            "__type": "GetConversationItemsJsonRequest:#Exchange",
            "Header": header(version: "V2017_08_18", timeZoneID: timeZoneID),
            "Body": [
                "__type": "GetConversationItemsRequest:#Exchange",
                "Conversations": [[
                    "__type": "ConversationRequestType:#Exchange",
                    "ConversationId": ["__type": "ItemId:#Exchange", "Id": conversationID],
                    "SyncState": "",
                ]],
                "ItemShape": readingItemShape(forConversation: true),
                "ShapeName": "ItemPart",
                "SortOrder": "DateOrderDescending",
                "MaxItemsToReturn": maxItems,
                "FoldersToIgnore": foldersToIgnore.map(folderID),
            ],
        ]
    }

    static func getItem(_ ref: MailItemRef, timeZoneID: String, allRecipients: Bool = false) -> [String: Any] {
        [
            "__type": "GetItemJsonRequest:#Exchange",
            "Header": header(version: "V2017_08_18", timeZoneID: timeZoneID),
            "Body": [
                "__type": "GetItemRequest:#Exchange",
                "ItemShape": readingItemShape(forConversation: false, maximumRecipients: allRecipients ? maximumRecipientsForReview : maximumRecipientsToReturn),
                "ItemIds": [itemID(ref)],
                "ShapeName": "ItemNormalizedBody",
                "InternetMessageId": NSNull(),
            ],
        ]
    }

    // MARK: - Changes in the user's own mailbox

    static func updateItem(_ target: MailItemTarget, update: MailItemUpdate, timeZoneID: String) -> [String: Any] {
        updateItems([target], update: update, timeZoneID: timeZoneID)
    }

    /// The `__type` of the item a change carries. `Message` is what OWA sends, and for `IsRead`
    /// it binds every message, invitations included. A flag or categories on a meeting message
    /// sent as `Message` fail with `ErrorItemNotFound` ("ID type 9; actual type 12"), and OWA's
    /// JSON does not deserialize `MeetingRequestMessage` and its kin there (HTTP 500 "Cannot
    /// deserialize UpdateItemJsonRequest"): those go as the base `Item`, which holds both fields.
    static func itemType(for update: MailItemUpdate, kind: MailItemKind) -> String {
        switch update {
        case .isRead: "Message:#Exchange"
        case .flag, .categories: kind.isMeetingMessage ? "Item:#Exchange" : "Message:#Exchange"
        }
    }

    /// One `UpdateItem` for several messages: an `ItemChange` per message, each with the type
    /// `itemType(for:kind:)` gives it.
    static func updateItems(_ targets: [MailItemTarget], update: MailItemUpdate, timeZoneID: String) -> [String: Any] {
        let field: String
        let value: (String, Any)
        switch update {
        case .isRead(let isRead):
            field = "IsRead"
            value = ("IsRead", isRead)
        case .categories(let names):
            field = "Categories"
            value = ("Categories", names)
        case .flag(let status):
            field = "Flag"
            value = ("Flag", ["__type": "FlagType:#Exchange", "FlagStatus": status.rawValue])
        }
        return [
            "__type": "UpdateItemJsonRequest:#Exchange",
            "Header": header(version: "Exchange2015", timeZoneID: timeZoneID),
            "Body": [
                "__type": "UpdateItemRequest:#Exchange",
                "ItemChanges": targets.map { target in [
                    "__type": "ItemChange:#Exchange",
                    "Updates": [[
                        "__type": "SetItemField:#Exchange",
                        "Path": propertyURI(field),
                        "Item": ["__type": itemType(for: update, kind: target.kind), value.0: value.1] as [String: Any],
                    ]],
                    "ItemId": itemID(target.ref),
                ] as [String: Any] },
                "ConflictResolution": "AlwaysOverwrite",
                "ClientSupportsIrm": true,
                "SendCalendarInvitationsOrCancellations": "SendToNone",
                "MessageDisposition": "SaveOnly",
                // Never send a read receipt: OWA itself passes `true` for read-state changes, and a
                // sender who asked for one learns nothing from this client.
                "SuppressReadReceipts": true,
                "OutboundCharset": "AlwaysUTF8",
                "PromoteEmojiContentToInlineAttachmentsCount": 0,
                "UnpromotedInlineImageCount": 0,
            ],
        ]
    }

    static func moveItems(_ refs: [MailItemRef], to folder: [String: Any], timeZoneID: String) -> [String: Any] {
        [
            "__type": "MoveItemJsonRequest:#Exchange",
            "Header": header(version: "Exchange2013", timeZoneID: timeZoneID),
            "Body": [
                "__type": "MoveItemRequest:#Exchange",
                "ItemIds": refs.map { ["__type": "ItemId:#Exchange", "Id": $0.id] },
                "ToFolderId": ["__type": "TargetFolderId:#Exchange", "BaseFolderId": folder],
            ],
        ]
    }

    // MARK: - Search

    static func searchScope(_ scope: MailSearchScope) -> [[String: Any]] {
        [[
            "__type": "PrimaryMailboxSearchScopeType:#Exchange",
            "FolderScope": ["__type": "SearchFolderScopeType:#Exchange", "BaseFolderId": folderReference(scope)],
        ]]
    }

    static func startSearchSession(sessionID: String, scope: MailSearchScope, timeZoneID: String) -> [String: Any] {
        [
            "__type": "StartSearchSessionJsonRequest:#Exchange",
            "Header": header(version: "Exchange2013", timeZoneID: timeZoneID),
            "Body": [
                "__type": "StartSearchSessionRequest:#Exchange",
                "SearchSessionId": sessionID,
                "WarmupOptions": 16_777_215,
                "SuggestionTypes": 1,
                "SearchScope": searchScope(scope),
                "IdFormat": "EwsId",
                "ApplicationId": "Owa",
            ],
        ]
    }

    static func endSearchSession(sessionID: String, timeZoneID: String) -> [String: Any] {
        [
            "__type": "EndSearchSessionJsonRequest:#Exchange",
            "Header": header(version: "Exchange2013", timeZoneID: timeZoneID),
            "Body": ["__type": "EndSearchSessionRequest:#Exchange", "SearchSessionId": sessionID],
        ]
    }

    /// Refiner queries for the filters of `query`: several of them mean "and".
    static func refinerQueries(for query: MailSearchQuery) -> [String] {
        var queries = query.from.map { "ShallowRefiner::SearchScope:from:\"\($0.replacingOccurrences(of: "\"", with: ""))\"" }
        if let has = query.hasAttachments {
            queries.append("ShallowRefiner::SearchScope:hasattachment:\(has ? "true" : "false")")
        }
        if let folder = query.folderRefinerID {
            queries.append("ShallowRefiner::SearchScope:folderid:\(folder)")
        }
        return queries
    }

    /// Day bounds as OWA sends them: bare dates, the upper one the day *after* the last day.
    static func dateRestriction(from: Date?, to: Date?, calendar: Calendar) -> [String: Any]? {
        func day(_ date: Date) -> String {
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        }
        func condition(_ type: String, _ value: String) -> [String: Any] {
            [
                "__type": "\(type):#Exchange",
                "Item": propertyURI("DateTimeReceived"),
                "FieldURIOrConstant": [
                    "__type": "FieldURIOrConstantType:#Exchange",
                    "Item": ["__type": "Constant:#Exchange", "Value": value],
                ],
            ]
        }
        var items: [[String: Any]] = []
        if let to {
            let next = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: to)) ?? to
            items.append(condition("IsLessThanOrEqualTo", day(next)))
        }
        if let from {
            items.append(condition("IsGreaterThanOrEqualTo", day(calendar.startOfDay(for: from))))
        }
        guard !items.isEmpty else { return nil }
        let inner: [String: Any] = items.count == 1 ? items[0] : ["__type": "And:#Exchange", "Items": items]
        return ["__type": "RestrictionType:#Exchange", "Item": inner]
    }

    static func executeSearch(
        sessionID: String,
        query: MailSearchQuery,
        offset: Int,
        count: Int,
        calendar: Calendar,
        timeZoneID: String
    ) -> [String: Any] {
        let refiners = refinerQueries(for: query).map { ["__type": "DynamicRefinerQueryType:#Exchange", "RefinerQuery": $0] }
        return [
            "__type": "ExecuteSearchJsonRequest:#Exchange",
            "Header": header(version: "V2016_06_15", timeZoneID: timeZoneID),
            "Body": [
                "__type": "ExecuteSearchRequest:#Exchange",
                "ApplicationId": "Owa",
                "SearchSessionId": sessionID,
                "SearchScope": searchScope(query.scope),
                "Query": query.text.trimmingCharacters(in: .whitespacesAndNewlines),
                "SearchRefiners": refiners.isEmpty ? NSNull() : refiners,
                "SearchRestrictions": dateRestriction(from: query.receivedFrom, to: query.receivedTo, calendar: calendar) ?? NSNull(),
                "IdFormat": "EwsId",
                // Only the first page: the server computes them over the whole result set.
                "RetrieveRefiners": offset == 0,
                "MaxRefinersCountPerRefinerType": 5,
                "ItemTypes": "MailConversations",
                "ResultRowOffset": offset,
                "ResultRowCount": count,
                "MaxResultsCountHint": searchResultsCap,
                "MaxPreviewLength": 60,
                "PropertySetName": "Owa16",
                "SortOrder": "DateTime",
                "IncludeDeleted": true,
                "Scenario": "MailSearch",
            ],
        ]
    }

    // MARK: - Sending (EWS SOAP)

    /// The text typed by the user, as the HTML body of an outgoing message (`RichTextHTML`):
    /// nothing the user typed is interpreted as markup. Each U+FFFC becomes the next of
    /// `inlineImages` by its `cid:`; one with no picture left is dropped.
    static func outgoingBodyHTML(_ body: RichText, inlineImages: [MailInlineImage] = []) -> String {
        let fragment = RichTextHTML.fragment(body, inlineImages: inlineImages)
        let inner = fragment == "<div><br></div>" ? "<br>" : fragment
        return "<html><head><meta http-equiv=\"Content-Type\" content=\"text/html; charset=UTF-8\"></head>"
            + "<body dir=\"auto\"><div style=\"font-family: Calibri, Arial, sans-serif; font-size: 11pt;\">\(inner)</div></body></html>"
    }

    private static func recipientsXML(_ element: String, _ addresses: [String]) -> String {
        guard !addresses.isEmpty else { return "" }
        let mailboxes = addresses.map {
            "<t:Mailbox><t:EmailAddress>\(OWACreateCalendarEventPayload.escapeXML($0))</t:EmailAddress></t:Mailbox>"
        }.joined()
        return "<t:\(element)>\(mailboxes)</t:\(element)>"
    }

    /// `CreateItem` for a new message, a reply, a reply-all or a forward. Exchange quotes the
    /// original message and keeps a forward's attachments itself.
    ///
    /// Element order follows the EWS schema: `Subject` (ItemType) before the recipients
    /// (MessageType) before `ReferenceItemId` and `NewBodyContent` (SmartResponseType).
    static func createMessageSOAP(_ outgoing: MailOutgoing) -> String {
        let disposition = outgoing.send ? "SendAndSaveCopy" : "SaveOnly"
        let savedFolder = outgoing.send ? "sentitems" : "drafts"
        let html = outgoingBodyHTML(outgoing.body, inlineImages: outgoing.inlineImages).replacingOccurrences(of: "]]>", with: "]] >")
        let subject = outgoing.subject.trimmingCharacters(in: .whitespacesAndNewlines)
        let subjectXML = subject.isEmpty ? "" : "<t:Subject>\(OWACreateCalendarEventPayload.escapeXML(subject))</t:Subject>"
        let recipients = recipientsXML("ToRecipients", outgoing.to) + recipientsXML("CcRecipients", outgoing.cc)

        let itemXML: String
        if outgoing.kind == .new || outgoing.reference == nil {
            itemXML = """
            <t:Message>\(subjectXML)<t:Body BodyType="HTML"><![CDATA[\(html)]]></t:Body>\(recipients)</t:Message>
            """
        } else {
            let element: String = switch outgoing.kind {
            case .reply: "ReplyToItem"
            case .replyAll: "ReplyAllToItem"
            case .forward, .new: "ForwardItem"
            }
            let ref = outgoing.reference!
            let changeKey = ref.changeKey.map { #" ChangeKey="\#(OWACreateCalendarEventPayload.escapeXML($0))""# } ?? ""
            itemXML = """
            <t:\(element)>\(subjectXML)\(recipients)<t:ReferenceItemId Id="\(OWACreateCalendarEventPayload.escapeXML(ref.id))"\(changeKey)/>\
            <t:NewBodyContent BodyType="HTML"><![CDATA[\(html)]]></t:NewBodyContent></t:\(element)>
            """
        }

        return soapEnvelope("""
            <m:CreateItem MessageDisposition="\(disposition)">
              <m:SavedItemFolderId><t:DistinguishedFolderId Id="\(savedFolder)"/></m:SavedItemFolderId>
              <m:Items>\(itemXML)</m:Items>
            </m:CreateItem>
        """)
    }

    /// Pictures pasted into the text, attached to a saved draft as inline files its body refers
    /// to by `cid:`. A reply or a forward cannot carry attachments in `CreateItem` itself.
    static func createInlineAttachmentsSOAP(parent ref: MailItemRef, images: [MailInlineImage]) -> String {
        let files = images.map { image in
            "<t:FileAttachment><t:Name>\(OWACreateCalendarEventPayload.escapeXML(image.name))</t:Name>"
                + "<t:ContentType>\(OWACreateCalendarEventPayload.escapeXML(image.contentType))</t:ContentType>"
                + "<t:ContentId>\(OWACreateCalendarEventPayload.escapeXML(image.contentID))</t:ContentId>"
                + "<t:IsInline>true</t:IsInline>"
                + "<t:Content>\(image.data.base64EncodedString())</t:Content></t:FileAttachment>"
        }.joined()
        return soapEnvelope("""
            <m:CreateAttachment>
              <m:ParentItemId Id="\(OWACreateCalendarEventPayload.escapeXML(ref.id))"\(ref.changeKey.map { " ChangeKey=\"" + OWACreateCalendarEventPayload.escapeXML($0) + "\"" } ?? "")/>
              <m:Attachments>\(files)</m:Attachments>
            </m:CreateAttachment>
        """)
    }

    /// Sends a draft as it is on the server, a copy to Sent Items.
    static func sendItemSOAP(_ ref: MailItemRef) -> String {
        soapEnvelope("""
            <m:SendItem SaveItemToFolder="true">
              <m:ItemIds>\(itemIDXML(ref))</m:ItemIds>
              <m:SavedItemFolderId><t:DistinguishedFolderId Id="sentitems"/></m:SavedItemFolderId>
            </m:SendItem>
        """)
    }

    /// Removes a draft this app created for review and the user did not send.
    static func deleteItemSOAP(_ ref: MailItemRef) -> String {
        soapEnvelope("""
            <m:DeleteItem DeleteType="HardDelete">
              <m:ItemIds>\(itemIDXML(ref))</m:ItemIds>
            </m:DeleteItem>
        """)
    }

    private static func itemIDXML(_ ref: MailItemRef) -> String {
        let changeKey = ref.changeKey.map { " ChangeKey=\"" + OWACreateCalendarEventPayload.escapeXML($0) + "\"" } ?? ""
        return "<t:ItemId Id=\"" + OWACreateCalendarEventPayload.escapeXML(ref.id) + "\"" + changeKey + "/>"
    }

    private static func soapEnvelope(_ body: String) -> String {
        """
        <?xml version="1.0" encoding="utf-8"?>
        <soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/" \
        xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types" \
        xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages">
          <soap:Header>
            <t:RequestServerVersion Version="Exchange2013_SP1"/>
          </soap:Header>
          <soap:Body>
        \(body)
          </soap:Body>
        </soap:Envelope>
        """
    }
}
