import Foundation

/// Meetings outside the sync window, loaded for the MCP tools on demand, in memory only.
///
/// The sync window (start of day -7 days ... now +30 days) stays what the popover, reminders and
/// the invitation tracker see. Asked about a period beyond it, the tools load that period from the
/// account's provider in fixed blocks of `blockLength`, one `GetCalendarView` each — the size of a
/// regular sync request — and keep them here for `lifetime`. Blocks are aligned to a fixed origin,
/// so overlapping questions reuse the same blocks instead of loading the same weeks again.
///
/// Limits, so a model cannot turn a question into a crawl of the whole mailbox:
/// - at most `horizon` from now in either direction;
/// - at most `maxSpan` outside the sync window per call (the tools clip to it and say so);
/// - every Exchange block is one request of `MCPAccessGuard`'s budget.
@MainActor
final class MCPCalendarArchive {
    nonisolated static let blockLength: TimeInterval = 31 * 86_400
    nonisolated static let horizon: TimeInterval = 366 * 86_400
    nonisolated static let maxSpan: TimeInterval = 184 * 86_400
    /// Past meetings rarely change, but upcoming ones do, and a block covers both kinds alike.
    nonisolated static let lifetime: TimeInterval = 10 * 60
    /// About two years of one account's blocks: enough for any sequence of questions in a chat.
    nonisolated static let capacity = 24

    struct Key: Hashable {
        let accountID: UUID
        let block: Int
    }

    private struct Entry {
        let events: [CalendarEvent]
        let loadedAt: Date
    }

    private var entries: [Key: Entry] = [:]
    private var order: [Key] = []

    /// The blocks that together cover `range`.
    static func blocks(covering range: DateInterval) -> [Int] {
        let first = Int((range.start.timeIntervalSinceReferenceDate / blockLength).rounded(.down))
        // `end` is exclusive: a range ending exactly on a block boundary does not need the next one.
        let last = Int((range.end.timeIntervalSinceReferenceDate / blockLength).rounded(.up)) - 1
        return Array(first...max(first, last))
    }

    static func interval(of block: Int) -> DateInterval {
        let start = Date(timeIntervalSinceReferenceDate: Double(block) * blockLength)
        return DateInterval(start: start, duration: blockLength)
    }

    func events(for key: Key, now: Date) -> [CalendarEvent]? {
        guard let entry = entries[key], now.timeIntervalSince(entry.loadedAt) < Self.lifetime else { return nil }
        return entry.events
    }

    func store(_ events: [CalendarEvent], for key: Key, now: Date) {
        order.removeAll { $0 == key }
        order.append(key)
        entries[key] = Entry(events: events, loadedAt: now)
        while order.count > Self.capacity {
            entries.removeValue(forKey: order.removeFirst())
        }
    }

    /// Everything still held, expired blocks included: an `event_id` handed out from a block
    /// keeps resolving in get_event_details until the block is evicted.
    var allEvents: [CalendarEvent] {
        order.flatMap { entries[$0]?.events ?? [] }
    }

    var count: Int { entries.count }
}
