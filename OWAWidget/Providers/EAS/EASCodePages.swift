import Foundation

/// A WBXML tag identity: code page plus token.
///
/// Both halves matter. The same token means different things on different pages —
/// `0x08` is `Set` on page 18 and `PolicyType` on page 14 — so equality compares
/// page and code, and `name` is carried for diagnostics only.
struct WBTag: Hashable, Sendable {
    let page: Int
    let code: Int
    let name: String

    static func == (lhs: WBTag, rhs: WBTag) -> Bool {
        lhs.page == rhs.page && lhs.code == rhs.code
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(page)
        hasher.combine(code)
    }
}

/// Token tables from [MS-ASWBXML].
///
/// Confidence, because a wrong token in a *request* produces a silently missing field
/// rather than an error — the failure mode is data that never arrives, not a crash:
///
/// - **verified against the live server** — pages 0, 7, 14, 18. These round-trip today.
/// - **verified against the published specification** — pages 4 and 17.
/// - **UNVERIFIED, recalled** — pages 2, 8, 10, 15, 16. The specification pages for
///   these are not retrievable from the public web, and the source repository is closed.
///   Each is used only by a feature not yet built; verify by round-trip before trusting.
///
/// The decoder prints unmapped tokens as `pN_0xNN`, so dumping a real response is
/// enough to confirm a read-side table in one shot. Write-side tables need an actual
/// round-trip: write a value, re-read it, compare.
enum EASCodePages {

    /// Page 0 — AirSync. Verified against the live server.
    static let airSync: [Int: String] = [
        0x05: "Sync", 0x06: "Responses", 0x07: "Add", 0x08: "Change", 0x09: "Delete",
        0x0A: "Fetch", 0x0B: "SyncKey", 0x0C: "ClientId", 0x0D: "ServerId", 0x0E: "Status",
        0x0F: "Collection", 0x10: "Class", 0x12: "CollectionId", 0x13: "GetChanges",
        0x14: "MoreAvailable", 0x15: "WindowSize", 0x16: "Commands", 0x17: "Options",
        0x18: "FilterType", 0x19: "Truncation", 0x1B: "Conflict", 0x1C: "Collections",
        0x1D: "ApplicationData", 0x1E: "DeletesAsMoves", 0x20: "Supported",
        0x21: "SoftDelete", 0x22: "MIMESupport", 0x23: "MIMETruncation",
        0x24: "Wait", 0x25: "Limit", 0x26: "Partial",
    ]

    /// Page 2 — Email. UNVERIFIED beyond the fields the mail prototype exercised.
    static let email: [Int: String] = [
        0x05: "Attachment", 0x06: "Attachments", 0x07: "AttName", 0x08: "AttSize",
        0x09: "AttOid", 0x0A: "AttMethod", 0x0B: "AttRemoved", 0x0C: "Body",
        0x0D: "BodySize", 0x0E: "BodyTruncated", 0x0F: "DateReceived",
        0x10: "DisplayName", 0x11: "DisplayTo", 0x12: "Importance", 0x13: "MessageClass",
        0x14: "Subject", 0x15: "Read", 0x16: "To", 0x17: "Cc", 0x18: "From",
        0x19: "ReplyTo", 0x1A: "AllDayEvent", 0x1B: "Categories", 0x1C: "Category",
        0x1D: "DtStamp", 0x1E: "EndTime", 0x1F: "InstanceType", 0x20: "BusyStatus",
        0x21: "Location", 0x22: "MeetingRequest", 0x23: "Organizer",
        0x24: "RecurrenceId", 0x25: "Reminder", 0x26: "ResponseRequested",
        0x31: "StartTime", 0x32: "Sensitivity", 0x33: "TimeZone", 0x34: "GlobalObjId",
        0x35: "ThreadTopic", 0x36: "MIMEData", 0x37: "MIMETruncated", 0x38: "MIMESize",
        0x39: "InternetCPID", 0x3A: "Flag", 0x3B: "FlagStatus", 0x3C: "ContentClass",
        0x3D: "FlagType", 0x3E: "CompleteTime",
    ]

    /// Page 4 — Calendar. Verified against the published specification.
    ///
    /// Note there is no token `0x10`: the table jumps from `Category` to `DtStamp`.
    /// `Body` (0x0B) and `BodyTruncated` (0x0C) exist only in protocol 2.5; from 12.0
    /// onward the body arrives as AirSyncBase `Body` on page 17.
    static let calendar: [Int: String] = [
        0x05: "Timezone", 0x06: "AllDayEvent", 0x07: "Attendees", 0x08: "Attendee",
        0x09: "Email", 0x0A: "Name", 0x0B: "CalBody25", 0x0C: "BodyTruncated25",
        0x0D: "BusyStatus", 0x0E: "Categories", 0x0F: "Category",
        0x11: "DtStamp", 0x12: "EndTime", 0x13: "Exception", 0x14: "Exceptions",
        0x15: "Deleted", 0x16: "ExceptionStartTime", 0x17: "Location",
        0x18: "MeetingStatus", 0x19: "OrganizerEmail", 0x1A: "OrganizerName",
        0x1B: "Recurrence", 0x1C: "Type", 0x1D: "Until", 0x1E: "Occurrences",
        0x1F: "Interval", 0x20: "DayOfWeek", 0x21: "DayOfMonth", 0x22: "WeekOfMonth",
        0x23: "MonthOfYear", 0x24: "Reminder", 0x25: "Sensitivity", 0x26: "Subject",
        0x27: "StartTime", 0x28: "UID", 0x29: "AttendeeStatus", 0x2A: "AttendeeType",
        0x33: "DisallowNewTimeProposal", 0x34: "ResponseRequested",
        0x35: "AppointmentReplyTime", 0x36: "ResponseType", 0x37: "CalendarType",
        0x38: "IsLeapMonth", 0x39: "FirstDayOfWeek", 0x3A: "OnlineMeetingConfLink",
        0x3B: "OnlineMeetingExternalLink", 0x3C: "ClientUid",
    ]

    /// Page 7 — FolderHierarchy. Verified byte-for-byte against the specification example.
    static let folderHierarchy: [Int: String] = [
        0x05: "Folders", 0x06: "Folder", 0x07: "DisplayName", 0x08: "ServerId",
        0x09: "ParentId", 0x0A: "Type", 0x0B: "Response", 0x0C: "Status",
        0x0D: "ContentClass", 0x0E: "Changes", 0x0F: "Add", 0x10: "Delete",
        0x11: "Update", 0x12: "SyncKey", 0x13: "FolderCreate", 0x14: "FolderDelete",
        0x15: "FolderUpdate", 0x16: "FolderSync", 0x17: "Count",
    ]

    /// Page 8 — MeetingResponse. UNVERIFIED — verify by round-trip before M6 relies on it.
    static let meetingResponse: [Int: String] = [
        0x05: "CalendarId", 0x06: "CollectionId", 0x07: "MeetingResponse",
        0x08: "RequestId", 0x09: "Request", 0x0A: "Result", 0x0B: "Status",
        0x0C: "UserResponse", 0x0E: "InstanceId",
    ]

    /// Page 10 (0x0A) — ResolveRecipients. UNVERIFIED — verify before M7 relies on it.
    ///
    /// If `Availability` / `MergedFreeBusy` are wrong the response still parses, but with
    /// no free/busy data — indistinguishable from "the server publishes none". Dump the
    /// tree and look for `p10_0x??` to tell the two apart.
    static let resolveRecipients: [Int: String] = [
        0x05: "ResolveRecipients", 0x06: "Response", 0x07: "Status", 0x08: "Type",
        0x09: "Recipient", 0x0A: "DisplayName", 0x0B: "EmailAddress",
        0x0C: "Certificates", 0x0D: "Certificate", 0x0E: "MiniCertificate",
        0x0F: "Options", 0x10: "To", 0x11: "CertificateRetrieval",
        0x12: "RecipientCount", 0x13: "MaxCertificates", 0x14: "MaxAmbiguousRecipients",
        0x15: "CertificateCount", 0x16: "Availability", 0x17: "StartTime",
        0x18: "EndTime", 0x19: "MergedFreeBusy", 0x1A: "Picture", 0x1B: "MaxSize",
        0x1C: "Data", 0x1D: "MaxPictures",
    ]

    /// Page 14 (0x0E) — Provision. Verified against the live server.
    static let provision: [Int: String] = [
        0x05: "Provision", 0x06: "Policies", 0x07: "Policy", 0x08: "PolicyType",
        0x09: "PolicyKey", 0x0A: "Data", 0x0B: "Status", 0x0C: "RemoteWipe",
        0x0D: "EASProvisionDoc",
    ]

    /// Page 15 (0x0F) — Search. UNVERIFIED — verify before M7 relies on it.
    static let search: [Int: String] = [
        0x05: "Search", 0x07: "Store", 0x08: "Name", 0x09: "Query", 0x0A: "Options",
        0x0B: "Range", 0x0C: "Status", 0x0D: "Response", 0x0E: "Result",
        0x0F: "Properties", 0x10: "Total", 0x11: "EqualTo", 0x12: "Value",
        0x13: "And", 0x14: "Or", 0x15: "FreeText", 0x17: "DeepTraversal",
        0x18: "LongId", 0x19: "RebuildResults", 0x1A: "LessThan", 0x1B: "GreaterThan",
        0x1C: "Schema", 0x1D: "Supported", 0x1E: "UserName", 0x1F: "Password",
        0x20: "ConversationId", 0x21: "Picture", 0x22: "MaxSize", 0x23: "MaxPictures",
    ]

    /// Page 16 (0x10) — GAL. UNVERIFIED — verify before M7 relies on it.
    static let gal: [Int: String] = [
        0x05: "DisplayName", 0x06: "Phone", 0x07: "Office", 0x08: "Title",
        0x09: "Company", 0x0A: "Alias", 0x0B: "FirstName", 0x0C: "LastName",
        0x0D: "HomePhone", 0x0E: "MobilePhone", 0x0F: "EmailAddress",
        0x10: "Picture", 0x11: "Status", 0x12: "Data",
    ]

    /// Page 17 (0x11) — AirSyncBase. Verified against the published specification.
    static let airSyncBase: [Int: String] = [
        0x05: "BodyPreference", 0x06: "Type", 0x07: "TruncationSize", 0x08: "AllOrNone",
        0x0A: "Body", 0x0B: "Data", 0x0C: "EstimatedDataSize", 0x0D: "Truncated",
        0x0E: "Attachments", 0x0F: "Attachment", 0x10: "DisplayName",
        0x11: "FileReference", 0x12: "Method", 0x13: "ContentId",
        0x14: "ContentLocation", 0x15: "IsInline", 0x16: "NativeBodyType",
        0x17: "ContentType", 0x18: "Preview", 0x19: "BodyPartPreference",
        0x1A: "BodyPart", 0x1B: "Status",
    ]

    /// Page 18 (0x12) — Settings. `DeviceInformation` verified against the live server.
    static let settings: [Int: String] = [
        0x05: "Settings", 0x06: "Status", 0x07: "Get", 0x08: "Set",
        0x09: "Oof", 0x0A: "OofState", 0x0B: "StartTime", 0x0C: "EndTime",
        0x0D: "OofMessage", 0x0E: "AppliesToInternal",
        0x0F: "AppliesToExternalKnown", 0x10: "AppliesToExternalUnknown",
        0x11: "Enabled", 0x12: "ReplyMessage", 0x13: "BodyType",
        0x14: "DevicePassword", 0x15: "Password", 0x16: "DeviceInformation",
        0x17: "Model", 0x18: "IMEI", 0x19: "FriendlyName", 0x1A: "OS",
        0x1B: "OSLanguage", 0x1C: "PhoneNumber", 0x1D: "UserInformation",
        0x1E: "EmailAddresses", 0x1F: "SmtpAddress", 0x20: "UserAgent",
        0x21: "EnableOutboundSMS", 0x22: "MobileOperator",
    ]

    static let pages: [Int: [Int: String]] = [
        0: airSync,
        2: email,
        4: calendar,
        7: folderHierarchy,
        8: meetingResponse,
        10: resolveRecipients,
        14: provision,
        15: search,
        16: gal,
        17: airSyncBase,
        18: settings,
    ]

    /// Name for a token, or a `pN_0xNN` placeholder when the page or code is unmapped.
    /// Placeholders showing up in a dump are the signal that a table needs extending.
    static func name(page: Int, code: Int) -> String {
        pages[page]?[code] ?? String(format: "p%d_0x%02X", page, code)
    }
}

// MARK: - Tags used to build requests

/// Page 0 — AirSync.
enum AS {
    static let sync           = WBTag(page: 0, code: 0x05, name: "Sync")
    static let add            = WBTag(page: 0, code: 0x07, name: "Add")
    static let change         = WBTag(page: 0, code: 0x08, name: "Change")
    static let delete         = WBTag(page: 0, code: 0x09, name: "Delete")
    static let syncKey        = WBTag(page: 0, code: 0x0B, name: "SyncKey")
    static let clientId       = WBTag(page: 0, code: 0x0C, name: "ClientId")
    static let serverId       = WBTag(page: 0, code: 0x0D, name: "ServerId")
    static let status         = WBTag(page: 0, code: 0x0E, name: "Status")
    static let collection     = WBTag(page: 0, code: 0x0F, name: "Collection")
    static let collectionId   = WBTag(page: 0, code: 0x12, name: "CollectionId")
    static let getChanges     = WBTag(page: 0, code: 0x13, name: "GetChanges")
    static let moreAvailable  = WBTag(page: 0, code: 0x14, name: "MoreAvailable")
    static let windowSize     = WBTag(page: 0, code: 0x15, name: "WindowSize")
    static let commands       = WBTag(page: 0, code: 0x16, name: "Commands")
    static let options        = WBTag(page: 0, code: 0x17, name: "Options")
    static let filterType     = WBTag(page: 0, code: 0x18, name: "FilterType")
    static let collections    = WBTag(page: 0, code: 0x1C, name: "Collections")
    static let applicationData = WBTag(page: 0, code: 0x1D, name: "ApplicationData")
    static let deletesAsMoves = WBTag(page: 0, code: 0x1E, name: "DeletesAsMoves")
}

/// Page 4 — Calendar.
enum CAL {
    static let timezone       = WBTag(page: 4, code: 0x05, name: "Timezone")
    static let allDayEvent    = WBTag(page: 4, code: 0x06, name: "AllDayEvent")
    static let attendees      = WBTag(page: 4, code: 0x07, name: "Attendees")
    static let attendee       = WBTag(page: 4, code: 0x08, name: "Attendee")
    static let email          = WBTag(page: 4, code: 0x09, name: "Email")
    static let name           = WBTag(page: 4, code: 0x0A, name: "Name")
    static let busyStatus     = WBTag(page: 4, code: 0x0D, name: "BusyStatus")
    static let categories     = WBTag(page: 4, code: 0x0E, name: "Categories")
    static let category       = WBTag(page: 4, code: 0x0F, name: "Category")
    static let dtStamp        = WBTag(page: 4, code: 0x11, name: "DtStamp")
    static let endTime        = WBTag(page: 4, code: 0x12, name: "EndTime")
    static let exception      = WBTag(page: 4, code: 0x13, name: "Exception")
    static let exceptions     = WBTag(page: 4, code: 0x14, name: "Exceptions")
    static let deleted        = WBTag(page: 4, code: 0x15, name: "Deleted")
    static let exceptionStartTime = WBTag(page: 4, code: 0x16, name: "ExceptionStartTime")
    static let location       = WBTag(page: 4, code: 0x17, name: "Location")
    static let meetingStatus  = WBTag(page: 4, code: 0x18, name: "MeetingStatus")
    static let organizerEmail = WBTag(page: 4, code: 0x19, name: "OrganizerEmail")
    static let organizerName  = WBTag(page: 4, code: 0x1A, name: "OrganizerName")
    static let recurrence     = WBTag(page: 4, code: 0x1B, name: "Recurrence")
    static let type           = WBTag(page: 4, code: 0x1C, name: "Type")
    static let until          = WBTag(page: 4, code: 0x1D, name: "Until")
    static let occurrences    = WBTag(page: 4, code: 0x1E, name: "Occurrences")
    static let interval       = WBTag(page: 4, code: 0x1F, name: "Interval")
    static let dayOfWeek      = WBTag(page: 4, code: 0x20, name: "DayOfWeek")
    static let dayOfMonth     = WBTag(page: 4, code: 0x21, name: "DayOfMonth")
    static let weekOfMonth    = WBTag(page: 4, code: 0x22, name: "WeekOfMonth")
    static let monthOfYear    = WBTag(page: 4, code: 0x23, name: "MonthOfYear")
    static let reminder       = WBTag(page: 4, code: 0x24, name: "Reminder")
    static let sensitivity    = WBTag(page: 4, code: 0x25, name: "Sensitivity")
    static let subject        = WBTag(page: 4, code: 0x26, name: "Subject")
    static let startTime      = WBTag(page: 4, code: 0x27, name: "StartTime")
    static let uid            = WBTag(page: 4, code: 0x28, name: "UID")
    static let attendeeStatus = WBTag(page: 4, code: 0x29, name: "AttendeeStatus")
    static let attendeeType   = WBTag(page: 4, code: 0x2A, name: "AttendeeType")
    static let responseType   = WBTag(page: 4, code: 0x36, name: "ResponseType")
    static let calendarType   = WBTag(page: 4, code: 0x37, name: "CalendarType")
    static let isLeapMonth    = WBTag(page: 4, code: 0x38, name: "IsLeapMonth")
    static let firstDayOfWeek = WBTag(page: 4, code: 0x39, name: "FirstDayOfWeek")
    static let onlineMeetingConfLink = WBTag(page: 4, code: 0x3A, name: "OnlineMeetingConfLink")
    static let onlineMeetingExternalLink = WBTag(page: 4, code: 0x3B, name: "OnlineMeetingExternalLink")
}

/// Page 7 — FolderHierarchy.
enum FH {
    static let folderSync  = WBTag(page: 7, code: 0x16, name: "FolderSync")
    static let syncKey     = WBTag(page: 7, code: 0x12, name: "SyncKey")
    static let status      = WBTag(page: 7, code: 0x0C, name: "Status")
    static let changes     = WBTag(page: 7, code: 0x0E, name: "Changes")
    static let add         = WBTag(page: 7, code: 0x0F, name: "Add")
    static let serverId    = WBTag(page: 7, code: 0x08, name: "ServerId")
    static let displayName = WBTag(page: 7, code: 0x07, name: "DisplayName")
    static let type        = WBTag(page: 7, code: 0x0A, name: "Type")
}

/// Page 14 — Provision.
enum PR {
    static let provision  = WBTag(page: 14, code: 0x05, name: "Provision")
    static let policies   = WBTag(page: 14, code: 0x06, name: "Policies")
    static let policy     = WBTag(page: 14, code: 0x07, name: "Policy")
    static let policyType = WBTag(page: 14, code: 0x08, name: "PolicyType")
    static let policyKey  = WBTag(page: 14, code: 0x09, name: "PolicyKey")
    static let status     = WBTag(page: 14, code: 0x0B, name: "Status")
}

/// Page 17 — AirSyncBase.
enum ASB {
    static let bodyPreference = WBTag(page: 17, code: 0x05, name: "BodyPreference")
    static let type           = WBTag(page: 17, code: 0x06, name: "Type")
    static let truncationSize = WBTag(page: 17, code: 0x07, name: "TruncationSize")
    static let body           = WBTag(page: 17, code: 0x0A, name: "Body")
    static let data           = WBTag(page: 17, code: 0x0B, name: "Data")
    static let truncated      = WBTag(page: 17, code: 0x0D, name: "Truncated")
    static let nativeBodyType = WBTag(page: 17, code: 0x16, name: "NativeBodyType")
}

/// Page 18 — Settings.
enum ST {
    static let settings          = WBTag(page: 18, code: 0x05, name: "Settings")
    static let status            = WBTag(page: 18, code: 0x06, name: "Status")
    static let get               = WBTag(page: 18, code: 0x07, name: "Get")
    static let set               = WBTag(page: 18, code: 0x08, name: "Set")
    static let deviceInformation = WBTag(page: 18, code: 0x16, name: "DeviceInformation")
    static let model             = WBTag(page: 18, code: 0x17, name: "Model")
    static let friendlyName      = WBTag(page: 18, code: 0x19, name: "FriendlyName")
    static let os                = WBTag(page: 18, code: 0x1A, name: "OS")
    static let osLanguage        = WBTag(page: 18, code: 0x1B, name: "OSLanguage")
    static let userInformation   = WBTag(page: 18, code: 0x1D, name: "UserInformation")
    static let emailAddresses    = WBTag(page: 18, code: 0x1E, name: "EmailAddresses")
    static let smtpAddress       = WBTag(page: 18, code: 0x1F, name: "SmtpAddress")
    static let userAgent         = WBTag(page: 18, code: 0x20, name: "UserAgent")
}

/// Page 8 — MeetingResponse. **Token values are unverified** — see ``EASCodePages``.
///
/// A wrong token here does not fail loudly: the server either ignores the element or reads it
/// as another one, and the reply is accepted while nothing changes in the mailbox. Confirm by
/// round-trip — respond, resynchronise, check that `calendar:ResponseType` moved.
enum MR {
    static let meetingResponse = WBTag(page: 8, code: 0x07, name: "MeetingResponse")
    static let request         = WBTag(page: 8, code: 0x09, name: "Request")
    static let userResponse    = WBTag(page: 8, code: 0x0C, name: "UserResponse")
    static let collectionId    = WBTag(page: 8, code: 0x06, name: "CollectionId")
    static let requestId       = WBTag(page: 8, code: 0x08, name: "RequestId")
    static let instanceId      = WBTag(page: 8, code: 0x0E, name: "InstanceId")
    static let result          = WBTag(page: 8, code: 0x0A, name: "Result")
    static let status          = WBTag(page: 8, code: 0x0B, name: "Status")
    static let calendarId      = WBTag(page: 8, code: 0x05, name: "CalendarId")
}

/// Page 0 — the `Fetch` command, used to pull one item in full.
extension AS {
    static let fetch     = WBTag(page: 0, code: 0x0A, name: "Fetch")
    static let responses = WBTag(page: 0, code: 0x06, name: "Responses")
}

/// Page 10 — ResolveRecipients. **Token values are unverified** — see ``EASCodePages``.
///
/// The failure mode deserves naming: if `Availability` or `MergedFreeBusy` are wrong, the
/// response still parses and still yields names and addresses — just no free/busy data, which
/// is indistinguishable from a server that does not publish any. Dump the tree and look for
/// `p10_0x??` to tell the two apart.
enum RR {
    static let resolveRecipients = WBTag(page: 10, code: 0x05, name: "ResolveRecipients")
    static let response          = WBTag(page: 10, code: 0x06, name: "Response")
    static let status            = WBTag(page: 10, code: 0x07, name: "Status")
    static let type              = WBTag(page: 10, code: 0x08, name: "Type")
    static let recipient         = WBTag(page: 10, code: 0x09, name: "Recipient")
    static let displayName       = WBTag(page: 10, code: 0x0A, name: "DisplayName")
    static let emailAddress      = WBTag(page: 10, code: 0x0B, name: "EmailAddress")
    static let options           = WBTag(page: 10, code: 0x0F, name: "Options")
    static let to                = WBTag(page: 10, code: 0x10, name: "To")
    static let availability      = WBTag(page: 10, code: 0x16, name: "Availability")
    static let startTime         = WBTag(page: 10, code: 0x17, name: "StartTime")
    static let endTime           = WBTag(page: 10, code: 0x18, name: "EndTime")
    static let mergedFreeBusy    = WBTag(page: 10, code: 0x19, name: "MergedFreeBusy")
}

/// Page 15 — Search. **Token values are unverified** — see ``EASCodePages``.
enum SRCH {
    static let search     = WBTag(page: 15, code: 0x05, name: "Search")
    static let store      = WBTag(page: 15, code: 0x07, name: "Store")
    static let name       = WBTag(page: 15, code: 0x08, name: "Name")
    static let query      = WBTag(page: 15, code: 0x09, name: "Query")
    static let options    = WBTag(page: 15, code: 0x0A, name: "Options")
    static let range      = WBTag(page: 15, code: 0x0B, name: "Range")
    static let status     = WBTag(page: 15, code: 0x0C, name: "Status")
    static let response   = WBTag(page: 15, code: 0x0D, name: "Response")
    static let result     = WBTag(page: 15, code: 0x0E, name: "Result")
    static let properties = WBTag(page: 15, code: 0x0F, name: "Properties")
    static let total      = WBTag(page: 15, code: 0x10, name: "Total")
}

/// Page 16 — GAL, the properties a directory search returns. **Unverified.**
enum GAL {
    static let displayName  = WBTag(page: 16, code: 0x05, name: "DisplayName")
    static let phone        = WBTag(page: 16, code: 0x06, name: "Phone")
    static let office       = WBTag(page: 16, code: 0x07, name: "Office")
    static let title        = WBTag(page: 16, code: 0x08, name: "Title")
    static let company      = WBTag(page: 16, code: 0x09, name: "Company")
    static let alias        = WBTag(page: 16, code: 0x0A, name: "Alias")
    static let firstName    = WBTag(page: 16, code: 0x0B, name: "FirstName")
    static let lastName     = WBTag(page: 16, code: 0x0C, name: "LastName")
    static let mobilePhone  = WBTag(page: 16, code: 0x0E, name: "MobilePhone")
    static let emailAddress = WBTag(page: 16, code: 0x0F, name: "EmailAddress")
}
