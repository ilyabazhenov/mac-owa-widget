import Foundation

/// `get_changes`: what changed in the calendar and the inbox since the client's last cursor.
///
/// Read from `MCPChangeFeed`, which the app's own sync fills: the calendar part costs no request
/// to Exchange. The mail part keeps `MCPInboxWatcher` running while the client asks, and only for
/// a client the user allowed to read mail — this tool never asks that question itself.
@MainActor
final class MCPChangeTools {
    nonisolated static let toolName = "get_changes"
    nonisolated static let defaultLimit = 200
    nonisolated static let maxLimit = 500

    /// Whether this client's answer may carry mail.
    enum MailAccess: Sendable {
        case allowed
        /// Mail for assistants is off in the settings.
        case off
        /// The user has not allowed this client to read mail (or not answered yet).
        case notAllowed
    }

    private let calendarService: CalendarService
    private let calendarTools: MCPCalendarTools
    private let mailTools: MCPMailTools?
    private let watcher: MCPInboxWatcher?
    private let isEnabled: () -> Bool
    private let clock: () -> Date
    private let timeZoneProvider: () -> TimeZone
    private let checkInterval: () -> TimeInterval

    init(
        calendarService: CalendarService,
        calendarTools: MCPCalendarTools,
        mailTools: MCPMailTools?,
        watcher: MCPInboxWatcher?,
        isEnabled: @escaping () -> Bool,
        checkInterval: @escaping () -> TimeInterval = { MCPInboxWatcher.defaultInterval },
        clock: @escaping () -> Date = { Date() },
        timeZone: @escaping () -> TimeZone = { AppTimeZone.zone }
    ) {
        self.calendarService = calendarService
        self.calendarTools = calendarTools
        self.mailTools = mailTools
        self.watcher = watcher
        self.isEnabled = isEnabled
        self.checkInterval = checkInterval
        self.clock = clock
        self.timeZoneProvider = timeZone
    }

    var feed: MCPChangeFeed { calendarService.changeFeed }

    func call(arguments: [String: JSONValue], mail access: MailAccess) -> MCPToolResult {
        guard isEnabled() else { return .failure(.serverDisabled, MCPCalendarTools.disabledMessage) }
        let cursor: String?
        switch arguments["since_cursor"] {
        case nil, .null?: cursor = nil
        case .string(let value)?: cursor = value
        default: return .failure(.invalidArgument, "`since_cursor` must be a string: the `cursor` of the previous get_changes answer")
        }
        var limit = Self.defaultLimit
        if let raw = arguments["limit"] {
            guard let value = raw.intValue, (1...Self.maxLimit).contains(value) else {
                return .failure(.invalidArgument, "`limit` must be an integer from 1 to \(Self.maxLimit)")
            }
            limit = value
        }

        let now = clock()
        let coder = MCPDateCoder(timeZone: timeZoneProvider())
        var mailState = mailStatus(access)
        if access == .allowed, let watcher, mailTools != nil {
            mailState = watcher.touch().rawValue
        }
        let includeMail = mailState == MCPInboxWatcher.State.watching.rawValue
        let page = feed.page(since: cursor, limit: limit, includeMail: includeMail)

        var changes: [JSONValue] = []
        for entry in page.entries {
            switch entry.change {
            case .calendar(let change):
                changes.append(calendarTools.changeJSON(entry, change, now: now, coder: coder))
            case .mail(let change):
                if let mailTools { changes.append(mailTools.changeJSON(entry, change, coder: coder)) }
            }
        }

        var result = calendarTools.statusFields(now: now, coder: coder)
        result["cursor"] = .string(page.cursor)
        result["reset"] = .bool(page.reset != nil)
        if let reset = page.reset { result["reset_reason"] = .string(reset.rawValue) }
        result["has_more"] = .bool(page.hasMore)
        result["changes"] = .array(changes)
        result["calendar"] = ["state": .string(feed.hasCalendarBaseline ? "watching" : "waiting_for_first_sync")]
        var mail: [String: JSONValue] = ["state": .string(mailState)]
        if includeMail || mailState == MCPInboxWatcher.State.starting.rawValue {
            let checked = calendarService.mailAccounts.compactMap { watcher?.checkedAt($0.id) }.min()
            mail["checked_at"] = .optional(checked.map(coder.string))
            mail["check_every_seconds"] = .int(Int64(checkInterval().rounded()))
        }
        result["mail"] = .object(mail)
        // The switches ring the subscription too: a client re-reads them here.
        result["settings"] = calendarTools.settingsJSON()
        return .success(result)
    }

    private func mailStatus(_ access: MailAccess) -> String {
        switch access {
        case .allowed: mailTools == nil || watcher == nil ? "off" : MCPInboxWatcher.State.starting.rawValue
        case .off: "off"
        case .notAllowed: "not_allowed"
        }
    }
}
