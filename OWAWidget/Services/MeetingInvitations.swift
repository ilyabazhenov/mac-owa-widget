import Foundation

// MARK: - Model

/// What happened to a meeting someone else organised, in the terms the user cares about.
enum MeetingInvitationChange: Sendable, Hashable {
    /// A meeting that was not on the calendar at the previous sync and still awaits an answer.
    case invited
    /// The organiser moved a meeting the user already knew about.
    case rescheduled(previousStart: Date, previousEnd: Date)
    /// The organiser cancelled a meeting the user already knew about.
    case cancelled

    /// Panel order: what needs an answer first, then what is only worth knowing.
    var displayRank: Int {
        switch self {
        case .invited: 0
        case .rescheduled: 1
        case .cancelled: 2
        }
    }

    fileprivate var groupingKey: String {
        switch self {
        case .invited: "invited"
        case .rescheduled: "rescheduled"
        case .cancelled: "cancelled"
        }
    }
}

/// One row of the invitation panel. Occurrences of one series arrive as separate calendar items
/// with separate identifiers, so they are folded into a single alert instead of one row each.
struct MeetingInvitationAlert: Sendable, Hashable, Identifiable {
    let change: MeetingInvitationChange
    /// Every occurrence folded into this alert, earliest first. The first one represents the row.
    let eventIDs: [String]
    let accountID: UUID
    let title: String
    let organizer: String?
    let startDate: Date
    let endDate: Date
    let isAllDay: Bool

    var id: String { change.groupingKey + ":" + eventIDs.joined(separator: "|") }
    var representativeEventID: String { eventIDs[0] }
    var occurrenceCount: Int { eventIDs.count }
}

/// Meetings awaiting an answer, folded the same way as alerts. Feeds the menu bar badge and the
/// popover's "awaiting response" section.
struct MeetingInvitationGroup: Sendable, Hashable, Identifiable {
    /// Occurrences, earliest first.
    let events: [CalendarEvent]

    var id: String { events.map(\.id).joined(separator: "|") }
    var representative: CalendarEvent { events[0] }
    var occurrenceCount: Int { events.count }
}

/// Start, end and cancellation of a tracked meeting at the last processed sync — the minimum
/// needed to notice a move or a cancellation. Titles and attendees are deliberately left out:
/// the state is persisted, and none of that is needed to compare.
struct MeetingInvitationFingerprint: Codable, Sendable, Hashable {
    let startDate: Date
    let endDate: Date
    let isCancelled: Bool
    /// Accepted or tentatively accepted at that sync. Only such a meeting was in the user's plans,
    /// so only its cancellation is news; Exchange may also reset the answer on the cancelled item.
    let wasCommitted: Bool

    init(startDate: Date, endDate: Date, isCancelled: Bool, wasCommitted: Bool = false) {
        self.startDate = startDate
        self.endDate = endDate
        self.isCancelled = isCancelled
        self.wasCommitted = wasCommitted
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        startDate = try c.decode(Date.self, forKey: .startDate)
        endDate = try c.decode(Date.self, forKey: .endDate)
        isCancelled = try c.decode(Bool.self, forKey: .isCancelled)
        wasCommitted = try c.decodeIfPresent(Bool.self, forKey: .wasCommitted) ?? false
    }
}

struct MeetingInvitationTrackerState: Codable, Sendable, Equatable {
    /// Accounts whose calendar has been seen at least once. Until then every meeting of the
    /// account would look new, so the first sync after enabling the feature (or adding an
    /// account) is recorded without raising anything.
    var baselinedAccountIDs: Set<UUID> = []
    var fingerprints: [String: MeetingInvitationFingerprint] = [:]
    /// Invitations announced by the panel that still await an answer and were not hidden. This,
    /// not "everything unanswered", is what the badge counts: people who never answer recurring
    /// or forwarded meetings would otherwise carry a permanent badge of forty.
    var unhandledEventIDs: Set<String> = []

    static let empty = MeetingInvitationTrackerState()

    init(
        baselinedAccountIDs: Set<UUID> = [],
        fingerprints: [String: MeetingInvitationFingerprint] = [:],
        unhandledEventIDs: Set<String> = []
    ) {
        self.baselinedAccountIDs = baselinedAccountIDs
        self.fingerprints = fingerprints
        self.unhandledEventIDs = unhandledEventIDs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        baselinedAccountIDs = try c.decodeIfPresent(Set<UUID>.self, forKey: .baselinedAccountIDs) ?? []
        fingerprints = try c.decodeIfPresent([String: MeetingInvitationFingerprint].self, forKey: .fingerprints) ?? [:]
        unhandledEventIDs = try c.decodeIfPresent(Set<String>.self, forKey: .unhandledEventIDs) ?? []
    }
}

// MARK: - Policy

enum MeetingInvitationPolicy {
    /// Meetings organised by someone else on a calendar that can answer invitations.
    ///
    /// `changeKey` is the same capability test the detail panel uses for its RSVP buttons: only
    /// Exchange items carry one. Read-only EventKit calendars are left out on purpose — holiday
    /// and subscribed calendars report "not responded" for every entry, and there is nothing the
    /// widget could answer on them anyway.
    static func isTracked(_ event: CalendarEvent) -> Bool {
        event.changeKey != nil && !event.isOrganizer && event.responseType != .organizer
    }

    static func isCommitted(_ event: CalendarEvent) -> Bool {
        event.responseType == .accepted || event.responseType == .tentative
    }

    /// Subject without the "Canceled:" prefix Exchange adds on cancellation: the panel already
    /// says "cancelled" and strikes the title through, so the prefix only repeats it.
    static func displayTitle(of event: CalendarEvent) -> String {
        let trimmed = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()
        for prefix in ["отменено:", "cancelled:", "canceled:"] where lowered.hasPrefix(prefix) {
            let stripped = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            return stripped.isEmpty ? trimmed : stripped
        }
        return trimmed
    }

    static func isAwaitingResponse(_ event: CalendarEvent, now: Date) -> Bool {
        isTracked(event)
            && event.responseType == .notResponded
            && !event.isEffectivelyCancelled
            && event.endDate > now
    }

    static func pendingGroups(in events: [CalendarEvent], now: Date) -> [MeetingInvitationGroup] {
        group(events.filter { isAwaitingResponse($0, now: now) })
            .map(MeetingInvitationGroup.init(events:))
    }

    /// Folds occurrences of one series together: same account, same subject, same organiser.
    ///
    /// Exchange gives every occurrence its own item identifier and `GetCalendarView` does not
    /// return the series master, so the subject is the best series key available. Two unrelated
    /// one-off meetings with an identical subject from the same person fold as well; the row then
    /// says "series (2)" and still opens the right meeting.
    static func group(_ events: [CalendarEvent]) -> [[CalendarEvent]] {
        var order: [String] = []
        var buckets: [String: [CalendarEvent]] = [:]
        for event in events.sorted(by: { $0.startDate < $1.startDate }) {
            let key = seriesKey(for: event)
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(event)
        }
        return order.compactMap { buckets[$0] }
    }

    /// Compares the calendar against the previous sync.
    ///
    /// - Parameters:
    ///   - events: the complete event list after the sync, including meetings kept from accounts
    ///     that were not refreshed this time.
    ///   - refreshedAccountIDs: accounts fetched successfully in this pass. They become baselined;
    ///     an account's meetings only raise alerts once it was baselined *before* this pass.
    /// - Returns: alerts to show and the state to persist for the next comparison.
    static func diff(
        previous: MeetingInvitationTrackerState,
        events: [CalendarEvent],
        refreshedAccountIDs: Set<UUID>,
        now: Date
    ) -> (alerts: [MeetingInvitationAlert], next: MeetingInvitationTrackerState) {
        let tracked = events.filter { isTracked($0) && $0.endDate > now }

        var changes: [(MeetingInvitationChange, CalendarEvent)] = []
        for event in tracked where refreshedAccountIDs.contains(event.accountID) {
            if let known = previous.fingerprints[event.id] {
                if !known.isCancelled && event.isEffectivelyCancelled {
                    // A cancelled invitation the user never accepted was never in their plans:
                    // it just leaves the badge, silently.
                    if known.wasCommitted || isCommitted(event) {
                        changes.append((.cancelled, event))
                    }
                } else if !event.isEffectivelyCancelled,
                          event.responseType != .declined,
                          known.startDate != event.startDate || known.endDate != event.endDate {
                    changes.append((.rescheduled(previousStart: known.startDate, previousEnd: known.endDate), event))
                }
            } else if previous.baselinedAccountIDs.contains(event.accountID),
                      isAwaitingResponse(event, now: now) {
                changes.append((.invited, event))
            }
        }

        var next = MeetingInvitationTrackerState(
            baselinedAccountIDs: previous.baselinedAccountIDs.union(refreshedAccountIDs),
            fingerprints: [:],
            unhandledEventIDs: previous.unhandledEventIDs
        )
        // Anything the panel now asks an answer for joins the badge; a move resets the answer on
        // Exchange, so a rescheduled meeting that awaits one counts as news too.
        for (change, event) in changes where change != .cancelled && isAwaitingResponse(event, now: now) {
            next.unhandledEventIDs.insert(event.id)
        }
        next.unhandledEventIDs = stillUnhandled(next.unhandledEventIDs, in: events, now: now)
        for event in tracked {
            next.fingerprints[event.id] = MeetingInvitationFingerprint(
                startDate: event.startDate,
                endDate: event.endDate,
                isCancelled: event.isEffectivelyCancelled,
                wasCommitted: isCommitted(event)
            )
        }

        return (alerts(from: changes), next)
    }

    /// Drops invitations that were answered (here or anywhere else), cancelled, ended, or are no
    /// longer on the calendar at all.
    static func stillUnhandled(_ ids: Set<String>, in events: [CalendarEvent], now: Date) -> Set<String> {
        guard !ids.isEmpty else { return ids }
        let awaiting = Set(events.lazy.filter { isAwaitingResponse($0, now: now) }.map(\.id))
        return ids.intersection(awaiting)
    }

    private static func alerts(from changes: [(MeetingInvitationChange, CalendarEvent)]) -> [MeetingInvitationAlert] {
        var order: [String] = []
        var buckets: [String: [(MeetingInvitationChange, CalendarEvent)]] = [:]
        let ordered = changes.sorted {
            ($0.0.displayRank, $0.1.startDate) < ($1.0.displayRank, $1.1.startDate)
        }
        for change in ordered {
            let key = change.0.groupingKey + "\u{1F}" + seriesKey(for: change.1)
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(change)
        }
        return order.compactMap { key -> MeetingInvitationAlert? in
            guard let members = buckets[key], let leading = members.first else { return nil }
            let first = leading.1
            return MeetingInvitationAlert(
                change: leading.0,
                eventIDs: members.map(\.1.id),
                accountID: first.accountID,
                title: displayTitle(of: first),
                organizer: first.organizer,
                startDate: first.startDate,
                endDate: first.endDate,
                isAllDay: first.isAllDay
            )
        }
    }

    private static func seriesKey(for event: CalendarEvent) -> String {
        let title = displayTitle(of: event).lowercased()
        let organizer = (event.organizer ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return [event.accountID.uuidString, title, organizer, event.isAllDay ? "1" : "0"]
            .joined(separator: "\u{1F}")
    }
}

// MARK: - Tracker

@MainActor
protocol MeetingInvitationTracking: AnyObject {
    func process(
        events: [CalendarEvent],
        refreshedAccountIDs: Set<UUID>,
        now: Date
    ) -> [MeetingInvitationAlert]
    /// Invitations the badge counts. See ``MeetingInvitationTrackerState/unhandledEventIDs``.
    var unhandledEventIDs: Set<String> { get }
    /// Re-checks the badge against the calendar, e.g. right after an answer was sent.
    func refreshUnhandled(events: [CalendarEvent], now: Date)
    /// The user hid these invitations: they leave the badge without being answered.
    func dismiss(eventIDs: [String])
    func reset()
}

/// Keeps the comparison state between syncs — and across launches, so an invitation that arrived
/// while the app was closed is still reported on the first sync after it starts.
///
/// Stored through ``SecureStore``: the state holds calendar item identifiers and meeting times.
/// An unreadable container is treated as empty, which costs one silent re-baseline and never a
/// burst of false alerts.
@MainActor
final class MeetingInvitationTracker: MeetingInvitationTracking {
    static let storageName = "invitation-tracker"

    private let store: SecureCodableStore<MeetingInvitationTrackerState>
    private var state: MeetingInvitationTrackerState?

    init(secureStore: SecureStore = .shared) {
        self.store = SecureCodableStore(
            name: Self.storageName,
            legacyKey: nil,
            store: secureStore,
            policy: .treatAsEmpty
        )
    }

    var unhandledEventIDs: Set<String> { currentState.unhandledEventIDs }

    private var currentState: MeetingInvitationTrackerState {
        if let state { return state }
        let loaded = store.load() ?? .empty
        state = loaded
        return loaded
    }

    func refreshUnhandled(events: [CalendarEvent], now: Date) {
        var next = currentState
        next.unhandledEventIDs = MeetingInvitationPolicy.stillUnhandled(next.unhandledEventIDs, in: events, now: now)
        commit(next)
    }

    func dismiss(eventIDs: [String]) {
        var next = currentState
        next.unhandledEventIDs.subtract(eventIDs)
        commit(next)
    }

    private func commit(_ next: MeetingInvitationTrackerState) {
        guard next != currentState else { return }
        state = next
        _ = store.save(next)
    }

    func process(
        events: [CalendarEvent],
        refreshedAccountIDs: Set<UUID>,
        now: Date
    ) -> [MeetingInvitationAlert] {
        let previous = currentState
        let result = MeetingInvitationPolicy.diff(
            previous: previous,
            events: events,
            refreshedAccountIDs: refreshedAccountIDs,
            now: now
        )
        commit(result.next)
        return result.alerts
    }

    /// Forgets everything, so turning the feature back on starts from a fresh, silent baseline
    /// instead of replaying whatever happened while it was off.
    func reset() {
        state = nil
        store.clear()
    }
}
