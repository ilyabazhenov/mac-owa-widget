import Foundation

/// A meeting that appeared, changed or went away between two syncs.
struct MCPCalendarChange: Sendable, Equatable {
    enum Kind: String, Sendable {
        case created = "event_created"
        case updated = "event_updated"
        case removed = "event_removed"
    }

    let kind: Kind
    /// The meeting as the newer sync has it; for `removed`, as the older one had it.
    let event: CalendarEvent
    /// For `updated`: what changed, by the names `get_changes` documents.
    var fields: [String] = []
}

/// A conversation that appeared in the inbox, changed there or left it.
struct MCPMailChange: Sendable, Equatable {
    enum Kind: String, Sendable {
        case added = "mail_added"
        case updated = "mail_updated"
        case removed = "mail_removed"
    }

    let kind: Kind
    let accountID: UUID
    /// As the newer inbox page has it; for `removed`, as the older one had it.
    let conversation: MailConversationSummary
    var fields: [String] = []
}

enum MCPChange: Sendable, Equatable {
    case calendar(MCPCalendarChange)
    case mail(MCPMailChange)

    var isMail: Bool {
        if case .mail = self { return true }
        return false
    }
}

struct MCPChangeEntry: Sendable, Equatable {
    let seq: Int
    let date: Date
    let change: MCPChange
}

/// What changed in the calendar and the inbox, for `get_changes`. Fed by the app's own sync
/// (`CalendarService`) and the inbox watcher (`MCPInboxWatcher`); it never asks Exchange itself.
///
/// Memory only, like the mail it describes: the log holds the last `capacity` entries of the last
/// `lifetime`, and an app restart starts a new epoch. A cursor from before any of that is answered
/// with a reset, never with a silent gap — the client then reads the current state afresh.
///
/// A **baseline** is the first look at something (the first sync of an account, the first inbox
/// page after the watcher started): what came before it is unknown, so a cursor older than the
/// baseline resets too.
@MainActor
final class MCPChangeFeed {
    enum ResetReason: String, Sendable {
        case noCursor = "no_cursor"
        /// The app restarted (or the cursor came from another copy): the log is gone.
        case restarted
        /// Older than everything the log still holds.
        case expired
        case invalid
        /// A calendar account was read for the first time since the cursor.
        case calendarResync = "calendar_resync"
        /// The inbox watcher started (again) since the cursor: mail in between is unknown.
        case mailResync = "mail_resync"
    }

    struct Page: Sendable {
        let entries: [MCPChangeEntry]
        let cursor: String
        let reset: ResetReason?
        let hasMore: Bool
    }

    nonisolated static let capacity = 1_000
    nonisolated static let lifetime: TimeInterval = 24 * 60 * 60

    let epoch: String
    private let clock: () -> Date
    private let capacity: Int
    private(set) var lastSeq = 0
    private var entries: [MCPChangeEntry] = []
    /// The newest seq no longer in `entries`.
    private var droppedThrough = 0
    private var calendarBaseline: Int?
    private var mailBaselines: [UUID: Int] = [:]
    /// Called after anything was appended: the push to subscribed clients.
    var onAppend: (() -> Void)?

    init(epoch: String = MCPChangeFeed.makeEpoch(), capacity: Int = MCPChangeFeed.capacity, clock: @escaping () -> Date = { Date() }) {
        self.epoch = epoch
        self.capacity = capacity
        self.clock = clock
    }

    nonisolated static func makeEpoch() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10)).lowercased()
    }

    /// Whether the calendar has had its first sync in this run.
    var hasCalendarBaseline: Bool { calendarBaseline != nil }

    func hasMailBaseline(_ accountID: UUID) -> Bool { mailBaselines[accountID] != nil }

    // MARK: - Writing

    func markCalendarBaseline() {
        lastSeq += 1
        calendarBaseline = lastSeq
    }

    func markMailBaseline(_ accountID: UUID) {
        lastSeq += 1
        mailBaselines[accountID] = lastSeq
    }

    /// The watcher stopped looking: until it looks again, nobody may think the inbox is quiet.
    func dropMailBaselines() {
        mailBaselines.removeAll()
    }

    func append(_ changes: [MCPChange]) {
        guard !changes.isEmpty else { return }
        let now = clock()
        for change in changes {
            lastSeq += 1
            entries.append(MCPChangeEntry(seq: lastSeq, date: now, change: change))
        }
        if entries.count > capacity {
            let overflow = entries.count - capacity
            droppedThrough = entries[overflow - 1].seq
            entries.removeFirst(overflow)
        }
        onAppend?()
    }

    // MARK: - Reading

    /// Changes after `cursor`, oldest first. `includeMail: false` skips the mail entries (and the
    /// mail baselines) but still moves the cursor past them.
    func page(since cursor: String?, limit: Int, includeMail: Bool) -> Page {
        prune()
        let current = encode(lastSeq)
        guard let cursor, !cursor.isEmpty else { return Page(entries: [], cursor: current, reset: .noCursor, hasMore: false) }
        guard let (cursorEpoch, seq) = Self.decode(cursor) else {
            return Page(entries: [], cursor: current, reset: .invalid, hasMore: false)
        }
        guard cursorEpoch == epoch else { return Page(entries: [], cursor: current, reset: .restarted, hasMore: false) }
        guard seq <= lastSeq else { return Page(entries: [], cursor: current, reset: .invalid, hasMore: false) }
        if seq < droppedThrough { return Page(entries: [], cursor: current, reset: .expired, hasMore: false) }
        if let baseline = calendarBaseline, seq < baseline {
            return Page(entries: [], cursor: current, reset: .calendarResync, hasMore: false)
        }
        if includeMail, mailBaselines.values.contains(where: { seq < $0 }) {
            return Page(entries: [], cursor: current, reset: .mailResync, hasMore: false)
        }
        let after = entries.drop { $0.seq <= seq }.filter { includeMail || !$0.change.isMail }
        let taken = Array(after.prefix(max(1, limit)))
        let hasMore = after.count > taken.count
        let next = hasMore ? (taken.last?.seq ?? seq) : lastSeq
        return Page(entries: taken, cursor: encode(next), reset: nil, hasMore: hasMore)
    }

    private func prune() {
        let cutoff = clock().addingTimeInterval(-Self.lifetime)
        let stale = entries.prefix { $0.date < cutoff }
        guard let last = stale.last else { return }
        droppedThrough = max(droppedThrough, last.seq)
        entries.removeFirst(stale.count)
    }

    private func encode(_ seq: Int) -> String { "\(epoch)-\(seq)" }

    nonisolated static func decode(_ cursor: String) -> (epoch: String, seq: Int)? {
        let parts = cursor.trimmingCharacters(in: .whitespaces).split(separator: "-")
        guard parts.count == 2, let seq = Int(parts[1]), seq >= 0 else { return nil }
        return (String(parts[0]), seq)
    }
}
