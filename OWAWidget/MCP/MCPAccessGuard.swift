import Foundation

/// Gatekeeper for the MCP server's read requests to Exchange: `GetCalendarEvent` (one meeting's
/// attendees and agenda) and the address book search. Creating a meeting waits for the user
/// instead and only checks that sync is not blocked.
///
/// - Refuses outright while sync is blocked (rejected password, untrusted certificate,
///   unapproved login host). Each OWA call re-submits credentials once on 401/440, so an agent
///   looping over meetings with a wrong password would otherwise walk the account into an AD
///   lockout.
/// - Feeds failures back into `CalendarService`'s circuit breaker, so MCP traffic latches the
///   block exactly as sync does.
/// - Caps the rate (60 per minute app-wide) and the concurrency (2).
@MainActor
final class MCPAccessGuard {
    enum Denial: Equatable {
        case blocked(MCPToolError)
        case rateLimited

        var error: MCPToolError {
            switch self {
            case .blocked(let error): error
            case .rateLimited: MCPToolError(.rateLimited, "Too many requests to Exchange in the last minute. Wait a minute and retry, or narrow the request.")
            }
        }

        var message: String { error.message }
    }

    static let requestsPerMinute = 60
    static let maxConcurrentRequests = 2

    private let calendarService: CalendarService
    private let clock: () -> Date
    private var bucket: MCPTokenBucket
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(calendarService: CalendarService, clock: @escaping () -> Date = { Date() }) {
        self.calendarService = calendarService
        self.clock = clock
        self.bucket = MCPTokenBucket(capacity: Self.requestsPerMinute, perMinute: Self.requestsPerMinute, now: clock())
    }

    /// Takes `count` requests from the budget, or says why not. An operation that may fan out
    /// into several Exchange requests takes them all up front.
    func permitRequest(count: Int = 1) -> Denial? {
        if let block = Self.blockError(calendarService.syncStatus) {
            return .blocked(block)
        }
        return bucket.take(count, now: clock()) ? nil : .rateLimited
    }

    func acquireSlot() async {
        if active < Self.maxConcurrentRequests {
            active += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func releaseSlot() {
        if waiters.isEmpty {
            active = max(0, active - 1)
        } else {
            waiters.removeFirst().resume()
        }
    }

    func report(_ error: Error, context: String = "mcp.getCalendarEvent") {
        calendarService.reportExternalRequestFailure(error, context: context)
    }

    var isBlocked: Bool { calendarService.syncStatus.blocksSync }

    static func blockReason(_ status: SyncStatus) -> String? {
        blockError(status)?.message
    }

    /// Why no request may go to Exchange now, with its code; `nil` when requests may go.
    static func blockError(_ status: SyncStatus) -> MCPToolError? {
        switch status {
        case .authenticationRequired:
            MCPToolError(.authFailed, "OWA Widget needs the Exchange password re-entered (sync is paused to avoid locking the account). Ask the user to open OWA Widget.")
        case .certificateTrustRequired:
            MCPToolError(.trustRequired, "OWA Widget is waiting for the user to trust the Exchange server certificate. Ask the user to open OWA Widget.")
        case .loginHostApprovalRequired:
            MCPToolError(.trustRequired, "OWA Widget is waiting for the user to approve the Exchange login host. Ask the user to open OWA Widget.")
        default:
            nil
        }
    }
}

/// Attendees and agenda already fetched for MCP, in memory only.
///
/// `CalendarService.loadDetails` caches details on the event, but the next sync (every five
/// minutes) replaces the event and the details with it. Keyed by id and `changeKey`, so an edited
/// meeting (new `changeKey`) is fetched again instead of answered from stale details.
@MainActor
final class MCPEventDetailsCache {
    struct Entry: Equatable {
        let attendees: [EventAttendee]
        let body: String?
        var icalUID: String? = nil
    }

    let capacity: Int
    private var entries: [String: Entry] = [:]
    private var order: [String] = []

    init(capacity: Int = 500) {
        self.capacity = capacity
    }

    func entry(for event: CalendarEvent) -> Entry? {
        entries[Self.key(event)]
    }

    func store(_ details: CalendarEventDetails, for event: CalendarEvent) {
        let key = Self.key(event)
        if entries[key] == nil { order.append(key) }
        entries[key] = Entry(attendees: details.attendees, body: details.body, icalUID: details.icalUID)
        while order.count > capacity {
            entries.removeValue(forKey: order.removeFirst())
        }
    }

    var count: Int { entries.count }

    private static func key(_ event: CalendarEvent) -> String {
        "\(event.id)|\(event.changeKey ?? "")"
    }
}
