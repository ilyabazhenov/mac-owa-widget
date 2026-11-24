import Foundation

/// Why a tool refused, as a stable machine code next to the human text: one set for every tool,
/// so a client can map each code to one hint for its user ("turn it on in settings", "you
/// declined", "retry after the next sync") without parsing English.
///
/// The raw values are a contract with MCP clients: add codes, never rename or reuse one.
enum MCPErrorCode: String, CaseIterable, Sendable {
    /// MCP access is off in OWA Widget.
    case serverDisabled = "server_disabled"
    /// The user refused this client, or it could not be identified.
    case clientNotApproved = "client_not_approved"
    /// OWA Widget is asking the user about this client (or its mail access) and has no answer yet.
    case approvalPending = "approval_pending"
    /// Mail for assistants is off, or this client is not allowed to read mail.
    case mailNotAllowed = "mail_not_allowed"
    /// The tool's own setting is off; `setting` names it as the settings window does.
    case settingDisabled = "setting_disabled"
    /// The user pressed the refusing button in the confirmation panel.
    case userDeclined = "user_declined"
    /// The confirmation panel got no answer in time.
    case confirmationTimeout = "confirmation_timeout"
    /// Another confirmation of the same kind is still open, or the hourly panel cap is reached.
    case busy
    /// The client cancelled the call.
    case cancelled
    /// The event, conversation, folder, account or id is unknown (ids from before a restart too).
    case notFound = "not_found"
    /// It changed in Exchange after the last sync: retry after the next one.
    case stale
    /// The arguments are wrong.
    case invalidArgument = "invalid_argument"
    /// Not possible for this kind of item: a macOS calendar, a meeting the user organizes, a
    /// cancelled meeting.
    case notSupported = "not_supported"
    /// `move_mail` into or out of a folder assistants may not touch.
    case forbiddenFolder = "forbidden_folder"
    /// `move_mail` to the Archive of a mailbox that has none yet.
    case noArchiveFolder = "no_archive_folder"
    /// `respond_to_meeting` on something that is not an invitation to the user.
    case notInvitation = "not_invitation"
    /// The meeting is already over.
    case pastEvent = "past_event"
    /// OWA Widget has no data yet (still starting, not synced).
    case notReady = "not_ready"
    /// OWA Widget's request budget for assistants is spent for now.
    case rateLimited = "rate_limited"
    /// Exchange rejected the password: requests are stopped until the user re-enters it.
    case authFailed = "auth_failed"
    /// OWA Widget waits for the user to trust the server certificate or approve the login host.
    case trustRequired = "trust_required"
    /// No network or VPN: the request did not reach Exchange.
    case offline
    /// Exchange refused for another reason.
    case exchangeError = "exchange_error"
    /// The request went out but Exchange did not confirm it: it may have taken effect. Check
    /// before retrying.
    case unconfirmed
    /// `get_mail_attachment`: the file is larger than OWA Widget downloads (25 MB).
    case tooLarge = "too_large"
}

/// A tool setting a `setting_disabled` refusal points at. `get_status` and `get_changes` report
/// every case in `settings`, in this order.
enum MCPSettingID: String, Sendable, CaseIterable {
    case createMeetings = "create_meetings"
    case cancelMeetings = "cancel_meetings"
    case respondMeetings = "respond_meetings"
    case readMail = "read_mail"
    case prepareMail = "prepare_mail"
    case markMail = "mark_mail"
    case arrangeMail = "arrange_mail"
    case downloadAttachments = "download_attachments"

    var localizationKey: String {
        switch self {
        case .createMeetings: "mcp.createMeetings"
        case .cancelMeetings: "mcp.cancelMeetings"
        case .respondMeetings: "mcp.respondMeetings"
        case .readMail: "mcp.mail.read"
        case .prepareMail: "mcp.mail.send"
        case .markMail: "mcp.mail.organize"
        case .arrangeMail: "mcp.mail.arrange"
        case .downloadAttachments: "mcp.mail.attachments"
        }
    }

    /// The toggle's title as the settings window shows it, in the app's language.
    @MainActor
    var title: String { LocalizationService().tr(localizationKey) }
}

/// A refusal: the code, the text the model reads, and for `setting_disabled` the setting.
struct MCPToolError: Error, Equatable, Sendable {
    let code: MCPErrorCode
    let message: String
    private(set) var setting: MCPSettingID?
    /// `setting`'s title in the app's language when the refusal was made.
    private(set) var settingTitle: String?

    init(_ code: MCPErrorCode, _ message: String) {
        self.code = code
        self.message = message
    }

    /// An argument mistake: the most common refusal.
    init(_ message: String) {
        self.init(.invalidArgument, message)
    }

    /// The tool's setting is off. Mail for assistants as a whole keeps its own code,
    /// `mail_not_allowed`, with the setting named all the same.
    @MainActor
    static func settingOff(_ setting: MCPSettingID, _ message: String, code: MCPErrorCode = .settingDisabled) -> MCPToolError {
        var error = MCPToolError(code, message)
        error.setting = setting
        error.settingTitle = setting.title
        return error
    }

    /// The same refusal with more text after it ("… Nothing was sent.").
    func appending(_ tail: String) -> MCPToolError {
        var error = MCPToolError(code, message + tail)
        error.setting = setting
        error.settingTitle = settingTitle
        return error
    }

    /// The code for an error from a request to Exchange that did not go through.
    /// `mayHaveBeenSent` says whether the request may have reached Exchange and changed
    /// something there: a broken connection then is `unconfirmed`, not `offline`.
    static func code(for error: any Error, mayHaveBeenSent: Bool = false) -> MCPErrorCode {
        if let error = error as? MCPToolError { return error.code }
        if error is CancellationError { return .cancelled }
        if error is CalendarService.AddressBookUnavailableError { return .notReady }
        if let owa = error as? OWAError {
            switch owa {
            case .authenticationFailed, .notAuthenticated: return .authFailed
            case .untrustedCertificate, .loginHostApprovalRequired: return .trustRequired
            case .ewsError(let code) where OWARespondToMeetingPayload.isStaleChangeKeyCode(code): return .stale
            case .ewsError("ErrorItemNotFound"): return .notFound
            default: break
            }
        }
        if let mail = error as? MailError {
            switch mail {
            case .notFound: return .notFound
            case .notSupported: return .notSupported
            case .blocked: return .authFailed
            case .sendUncertain: return .unconfirmed
            case .serverError, .tooLarge, .recipientsUnverified: return .exchangeError
            }
        }
        if let url = error as? URLError {
            switch url.code {
            case .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
                 .internationalRoamingOff, .dataNotAllowed:
                return .offline
            case .timedOut, .networkConnectionLost:
                return mayHaveBeenSent ? .unconfirmed : .offline
            case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid,
                 .serverCertificateHasUnknownRoot, .clientCertificateRejected:
                return .trustRequired
            case .cancelled:
                return .cancelled
            default:
                break
            }
        }
        return mayHaveBeenSent ? .unconfirmed : .exchangeError
    }
}

/// The codes each tool can refuse with, listed in its description. A client that does not know
/// a code falls back to the text, which always says what happened.
enum MCPToolErrorCodes {
    /// Every tool: the server's own gate.
    static let gate: [MCPErrorCode] = [.serverDisabled, .clientNotApproved, .approvalPending]
    /// Every mail tool also passes the mail gate.
    static let mailGate: [MCPErrorCode] = gate + [.mailNotAllowed]
    /// A request to Exchange that did not go through.
    static let exchange: [MCPErrorCode] = [.rateLimited, .authFailed, .trustRequired, .offline, .exchangeError]
    /// Reading meetings beyond the sync window: the budget and a blocked sync stop it; a
    /// calendar that fails to load is reported in `unavailable_accounts`, not as a refusal.
    static let calendarRead: [MCPErrorCode] = gate + [.invalidArgument, .notReady, .rateLimited, .authFailed, .trustRequired]
    /// Tools that go to the Exchange address book or free/busy service.
    static let directory: [MCPErrorCode] = gate + [.invalidArgument, .notFound, .notSupported] + exchange
    /// A confirmation panel shown to the user.
    static let panel: [MCPErrorCode] = [.busy, .userDeclined, .confirmationTimeout, .cancelled]
    static let mailRead: [MCPErrorCode] = mailGate + [.invalidArgument, .notFound, .notReady, .notSupported] + exchange
    /// `failed[].code` of the batch mail tools.
    static let batchItem: [MCPErrorCode] = [.notFound] + exchange

    static func codes(for tool: String) -> [MCPErrorCode] {
        let codes: [MCPErrorCode]
        switch tool {
        case "get_status": codes = gate
        case "get_current_and_next", "get_changes": codes = gate + [.invalidArgument]
        case "list_events", "get_schedule_stats", "find_events_with_person": codes = calendarRead
        case "get_event_details": codes = calendarRead + [.notFound]
        case "match_event": codes = calendarRead + [.exchangeError]
        case "find_people", "find_free_slots": codes = directory
        case "get_person_profile": codes = directory + [.notReady]
        case "get_my_org": codes = directory + [.notReady]
        case "create_meeting":
            codes = gate + [.settingDisabled, .invalidArgument, .notFound, .notSupported] + panel
                + [.authFailed, .trustRequired, .offline, .unconfirmed]
        case "respond_to_meeting":
            codes = gate + [.mailNotAllowed, .settingDisabled, .invalidArgument, .notFound, .notSupported, .notInvitation, .pastEvent] + panel
                + [.stale] + exchange + [.unconfirmed]
        case "cancel_meeting":
            codes = gate + [.settingDisabled, .invalidArgument, .notFound, .notSupported, .pastEvent] + panel
                + [.stale, .authFailed, .trustRequired, .offline, .exchangeError, .unconfirmed]
        case "prepare_mail": codes = mailRead + [.settingDisabled] + panel + [.unconfirmed]
        case "set_mail_read", "set_mail_flag": codes = mailRead + [.settingDisabled]
        case "move_mail": codes = mailRead + [.settingDisabled, .forbiddenFolder, .noArchiveFolder]
        case "get_mail_attachment": codes = mailRead + [.settingDisabled, .tooLarge]
        default:
            codes = MCPMailTools.readToolNames.contains(tool) ? mailRead : gate
        }
        var seen: Set<MCPErrorCode> = []
        return codes.filter { seen.insert($0).inserted }
    }

    /// Whether the tool answers with per-item `failed[]` entries carrying `code`.
    static func hasBatchFailures(_ tool: String) -> Bool {
        ["set_mail_read", "move_mail", "set_mail_flag"].contains(tool)
    }

    /// The sentence appended to a tool's description.
    static func descriptionSuffix(for tool: String) -> String {
        var text = " Refusals (`isError: true`) carry `structuredContent.error_code`, one of: "
            + codes(for: tool).map { "`\($0.rawValue)`" }.joined(separator: ", ") + "."
        if codes(for: tool).contains(.settingDisabled) {
            text += " With `setting_disabled`, `setting` names the switch as OWA Widget's settings show it."
        }
        if hasBatchFailures(tool) {
            text += " Each `failed` entry carries `code` too: "
                + batchItem.map { "`\($0.rawValue)`" }.joined(separator: ", ") + "."
        }
        return text
    }
}
