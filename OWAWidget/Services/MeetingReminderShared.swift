import Foundation

// MARK: - Schedule (shared by system UN + in-app reminders)

struct MeetingReminderItem: Codable, Sendable, Hashable {
    let eventID: String
    let title: String
    let startDate: Date
    let endDate: Date
    let platform: MeetingPlatform
    let joinURL: URL?

    init(
        eventID: String,
        title: String,
        startDate: Date,
        endDate: Date,
        platform: MeetingPlatform,
        joinURL: URL?
    ) {
        self.eventID = eventID
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.platform = platform
        self.joinURL = joinURL
    }

    init(event: CalendarEvent) {
        self.init(
            eventID: event.id,
            title: event.title,
            startDate: event.startDate,
            endDate: event.endDate,
            platform: event.platform,
            joinURL: event.joinURL
        )
    }

    var hasJoinURL: Bool { joinURL != nil }
}

struct MeetingReminderCluster: Sendable, Hashable {
    let id: String
    let anchorEvent: CalendarEvent
    let items: [MeetingReminderItem]

    var hasMultipleMeetings: Bool { items.count > 1 }
}

enum MeetingReminderClusterBuilder {
    static let simultaneousWindow: TimeInterval = 5 * 60

    static func clusters(from events: [CalendarEvent], now: Date) -> [MeetingReminderCluster] {
        let candidates = events
            .filter { !$0.isAllDay && $0.endDate > now }
            .sorted { $0.startDate < $1.startDate }

        guard !candidates.isEmpty else { return [] }

        var grouped: [[CalendarEvent]] = []
        var currentGroup: [CalendarEvent] = []
        var groupAnchor: CalendarEvent?

        for event in candidates {
            if let anchor = groupAnchor,
               abs(event.startDate.timeIntervalSince(anchor.startDate)) <= simultaneousWindow {
                currentGroup.append(event)
            } else {
                if !currentGroup.isEmpty {
                    grouped.append(currentGroup)
                }
                currentGroup = [event]
                groupAnchor = event
            }
        }

        if !currentGroup.isEmpty {
            grouped.append(currentGroup)
        }

        return grouped.compactMap(cluster(from:))
    }

    private static func cluster(from events: [CalendarEvent]) -> MeetingReminderCluster? {
        guard let anchor = events.min(by: { $0.startDate < $1.startDate }) else { return nil }
        let ordered = events.sorted {
            let lhsRank = $0.joinURL == nil ? 1 : 0
            let rhsRank = $1.joinURL == nil ? 1 : 0
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            if $0.startDate != $1.startDate { return $0.startDate < $1.startDate }
            return $0.id < $1.id
        }
        let ids = ordered.map(\.id).joined(separator: "|")
        let clusterID = "\(Int(anchor.startDate.timeIntervalSince1970))-\(ids)"
        return MeetingReminderCluster(
            id: clusterID,
            anchorEvent: anchor,
            items: ordered.map(MeetingReminderItem.init(event:))
        )
    }
}

enum MeetingReminderSchedule {
    private static let debugDelaySecondsKey = "OWA_TEST_DELAY_SECONDS"
    private static let debugEventIDPrefix = "debug-reminder-"

    /// Delay until the reminder should fire, or `nil` if the event should be skipped.
    static func deliveryDelay(
        event: CalendarEvent,
        leadMinutes: Int,
        from now: Date
    ) -> TimeInterval? {
        #if DEBUG
        if event.id.hasPrefix(debugEventIDPrefix), let debugDelay = forcedDebugDelay() {
            return debugDelay
        }
        #endif

        guard !event.isAllDay, event.endDate > now else { return nil }

        let lead = TimeInterval(leadMinutes * 60)
        let secondsUntilIdealFire = event.startDate.timeIntervalSince(now) - lead
        if secondsUntilIdealFire > 1 {
            return secondsUntilIdealFire
        }
        if event.startDate > now {
            return max(1, event.startDate.timeIntervalSince(now) - 1)
        }
        return nil
    }

    #if DEBUG
    private static func forcedDebugDelay() -> TimeInterval? {
        let defaultsValue = UserDefaults.standard.double(forKey: debugDelaySecondsKey)
        if defaultsValue > 0 {
            return defaultsValue
        }

        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "-\(debugDelaySecondsKey)"),
           index + 1 < args.count,
           let delay = TimeInterval(args[index + 1]),
           delay > 0 {
            return delay
        }
        return nil
    }
    #endif
}

// MARK: - Copy (shared)

enum MeetingReminderText {
    static func reminderBody(
        event: CalendarEvent,
        leadMinutes: Int,
        localization: NotificationLocalization
    ) -> String {
        let locale = Locale(identifier: localization.localeIdentifier)
        let timeStr = shortTime(event.startDate, locale: locale)
        let minutes = localizedMinutes(leadMinutes, localeIdentifier: localization.localeIdentifier)
        if event.hasJoinURL {
            return String(format: localization.bodyWithJoinFormat, locale: locale, minutes, timeStr)
        }
        return String(format: localization.bodyWithoutJoinFormat, locale: locale, minutes, timeStr)
    }

    static func reminderBody(
        cluster: MeetingReminderCluster,
        leadMinutes: Int,
        localization: NotificationLocalization
    ) -> String {
        if cluster.items.count == 1 {
            return reminderBody(event: cluster.anchorEvent, leadMinutes: leadMinutes, localization: localization)
        }
        let locale = Locale(identifier: localization.localeIdentifier)
        let timeStr = shortTime(cluster.anchorEvent.startDate, locale: locale)
        let minutes = localizedMinutes(leadMinutes, localeIdentifier: localization.localeIdentifier)
        let meetings = localizedMeetings(cluster.items.count, localeIdentifier: localization.localeIdentifier)
        return "\(minutes) • \(timeStr) • \(meetings)"
    }

    static func title(
        cluster: MeetingReminderCluster,
        localeIdentifier: String
    ) -> String {
        if let only = cluster.items.first, cluster.items.count == 1 {
            return only.title
        }
        let meetings = localizedMeetings(cluster.items.count, localeIdentifier: localeIdentifier)
        if localeIdentifier == "ru" {
            return "Скоро начнутся: \(meetings)"
        }
        return "Starting soon: \(meetings)"
    }

    private static func shortTime(_ date: Date, locale: Locale) -> String {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        f.locale = locale
        return f.string(from: date)
    }

    private static func localizedMinutes(_ count: Int, localeIdentifier: String) -> String {
        if localeIdentifier == "ru" {
            let mod10 = count % 10
            let mod100 = count % 100
            if mod10 == 1 && mod100 != 11 { return "\(count) минута" }
            if (2...4).contains(mod10) && !(12...14).contains(mod100) { return "\(count) минуты" }
            return "\(count) минут"
        }
        return count == 1 ? "\(count) minute" : "\(count) minutes"
    }

    private static func localizedMeetings(_ count: Int, localeIdentifier: String) -> String {
        if localeIdentifier == "ru" {
            let mod10 = count % 10
            let mod100 = count % 100
            if mod10 == 1 && mod100 != 11 { return "\(count) встреча" }
            if (2...4).contains(mod10) && !(12...14).contains(mod100) { return "\(count) встречи" }
            return "\(count) встреч"
        }
        return count == 1 ? "\(count) meeting" : "\(count) meetings"
    }
}
