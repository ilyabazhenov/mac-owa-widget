import Foundation

@MainActor
final class MeetingEngagementStatsService {
    private struct StoredJoin: Codable, Hashable {
        let eventKey: String
        let dayKey: String
        let joinedAt: Date
        let source: MeetingJoinSource
    }

    private struct StoragePayload: Codable {
        var joins: [StoredJoin]
        var scope: MeetingEngagementScope
        var defaultPeriod: MeetingEngagementPeriod
    }

    // `nonisolated` so the migrator can name these keys without hopping to the main actor.
    nonisolated static let storageName = "engagement"
    nonisolated static let legacyDefaultsKey = "meetingEngagementStats.storage.v1"

    private let store: SecureCodableStore<StoragePayload>
    private let milestones = [10, 25, 50, 100, 250, 500]
    private var payload: StoragePayload

    var scope: MeetingEngagementScope { payload.scope }
    var defaultPeriod: MeetingEngagementPeriod { payload.defaultPeriod }

    init(secureStore: SecureStore = .shared, defaults: UserDefaults = .standard) {
        let store = SecureCodableStore<StoragePayload>(
            name: Self.storageName,
            legacyKey: Self.legacyDefaultsKey,
            store: secureStore,
            defaults: defaults,
            policy: .fallBackToLegacy
        )
        self.store = store
        self.payload = store.load()
            ?? StoragePayload(joins: [], scope: .joinableOnly, defaultPeriod: .today)
    }

    func setScope(_ scope: MeetingEngagementScope) {
        payload.scope = scope
        persist()
    }

    func setDefaultPeriod(_ period: MeetingEngagementPeriod) {
        payload.defaultPeriod = period
        persist()
    }

    func trackJoin(for event: CalendarEvent, source: MeetingJoinSource, at date: Date = Date()) {
        let join = StoredJoin(
            eventKey: eventKey(id: event.id, startDate: event.startDate),
            dayKey: dayKey(for: date),
            joinedAt: date,
            source: source
        )
        guard !payload.joins.contains(where: { $0.eventKey == join.eventKey && $0.dayKey == join.dayKey }) else {
            return
        }
        payload.joins.append(join)
        persist()
    }

    func trackJoin(eventID: String, startDate: Date, source: MeetingJoinSource, at date: Date = Date()) {
        let join = StoredJoin(
            eventKey: eventKey(id: eventID, startDate: startDate),
            dayKey: dayKey(for: date),
            joinedAt: date,
            source: source
        )
        guard !payload.joins.contains(where: { $0.eventKey == join.eventKey && $0.dayKey == join.dayKey }) else {
            return
        }
        payload.joins.append(join)
        persist()
    }

    func snapshot(events: [CalendarEvent], period: MeetingEngagementPeriod, now: Date = Date()) -> MeetingEngagementSnapshot {
        let periodStart = AppTimeZone.calendar.startOfDay(for: now)
        let periodEnd = AppTimeZone.calendar.date(byAdding: .day, value: period.dayCount, to: periodStart) ?? now

        let eligibleEvents = events.filter { event in
            guard event.startDate >= periodStart, event.startDate < periodEnd, !event.isEffectivelyCancelled else {
                return false
            }
            switch payload.scope {
            case .joinableOnly:
                return event.joinURLForActions != nil
            case .allEvents:
                return true
            }
        }

        let eligibleEventKeys = Set(eligibleEvents.map { eventKey(id: $0.id, startDate: $0.startDate) })
        let joinedCount = Set(payload.joins.filter { eligibleEventKeys.contains($0.eventKey) }.map(\.eventKey)).count
        let totalJoined = Set(payload.joins.map(\.eventKey)).count

        return MeetingEngagementSnapshot(
            period: period,
            scope: payload.scope,
            eligibleMeetings: eligibleEvents.count,
            joinedViaWidget: joinedCount,
            streakDays: currentStreakDays(now: now),
            totalJoined: totalJoined,
            nextMilestone: nextMilestone(for: totalJoined)
        )
    }

    private func currentStreakDays(now: Date) -> Int {
        let joinedDays = Set(payload.joins.map(\.dayKey))
        var streak = 0
        var cursor = AppTimeZone.calendar.startOfDay(for: now)

        while joinedDays.contains(dayKey(for: cursor)) {
            streak += 1
            guard let prev = AppTimeZone.calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = prev
        }
        return streak
    }

    private func nextMilestone(for total: Int) -> Int {
        milestones.first(where: { $0 > total }) ?? ((total / 100 + 1) * 100)
    }

    private func persist() {
        store.save(payload)
    }

    private func eventKey(id: String, startDate: Date) -> String {
        "\(id)|\(Int(startDate.timeIntervalSince1970))"
    }

    private func dayKey(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = AppTimeZone.zone
        formatter.calendar = AppTimeZone.calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
