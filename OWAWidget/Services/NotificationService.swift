import Foundation
import UserNotifications
import os.log

protocol UserNotificationCentering: Sendable {
    func setNotificationCategories(_ categories: Set<UNNotificationCategory>)
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
    func pendingNotificationRequests() async -> [UNNotificationRequest]
    func removePendingNotificationRequests(withIdentifiers identifiers: [String])
    func add(_ request: UNNotificationRequest) async throws
}

extension UNUserNotificationCenter: UserNotificationCentering {}

struct NotificationLocalization: Sendable, Equatable {
    let localeIdentifier: String
    let joinActionTitle: String
    let dismissActionTitle: String
    let bodyWithJoinFormat: String
    let bodyWithoutJoinFormat: String
    let clusterTitleFormat: String

    static let english = NotificationLocalization(
        localeIdentifier: "en",
        joinActionTitle: "Join",
        dismissActionTitle: "Dismiss",
        bodyWithJoinFormat: "Starts in %@ at %@. Tap Join to connect",
        bodyWithoutJoinFormat: "Starts in %@ at %@",
        clusterTitleFormat: "Starting soon: %@"
    )
}

actor NotificationService {
    static let categoryID = "MEETING_JOIN"
    static let actionID = "JOIN_MEETING"
    private let idPrefix = "owawidget."
    /// Legacy payload: the whole `[MeetingReminderItem]` list, titles and join URLs included.
    /// No longer written — still read, so reminders scheduled by the previous version keep
    /// working until they fire.
    static let itemsUserInfoKey = "meetingItems"
    static let eventIDsUserInfoKey = "meetingEventIDs"

    private let center: any UserNotificationCentering
    private let log = Logger(subsystem: "com.owawidget", category: "NotificationService")

    init(center: any UserNotificationCentering = UNUserNotificationCenter.current()) {
        self.center = center
    }

    func setup(localization: NotificationLocalization = .english) {
        let joinAction = UNNotificationAction(
            identifier: NotificationService.actionID,
            title: localization.joinActionTitle,
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: NotificationService.categoryID,
            actions: [joinAction],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])
    }

    func requestAuthorization() async {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            log.info("Notification authorization granted: \(granted)")
        } catch {
            log.error("Notification authorization error: \(error)")
        }
    }

    func removeAllPendingMeetingNotifications() async {
        let pending = await center.pendingNotificationRequests()
        let toRemove = pending.map(\.identifier).filter { $0.hasPrefix(idPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: toRemove)
    }

    func scheduleNotifications(
        for events: [CalendarEvent],
        leadMinutes: Int,
        localization: NotificationLocalization = .english
    ) async {
        await removeAllPendingMeetingNotifications()
        let now = Date()
        let clusters = MeetingReminderClusterBuilder.clusters(from: events, now: now)

        for cluster in clusters {
            guard let timeInterval = MeetingReminderSchedule.deliveryDelay(
                event: cluster.anchorEvent,
                leadMinutes: leadMinutes,
                from: now
            ) else { continue }

            let content = UNMutableNotificationContent()
            content.title = MeetingReminderText.title(cluster: cluster, localization: localization)
            content.body = MeetingReminderText.reminderBody(cluster: cluster, leadMinutes: leadMinutes, localization: localization)
            content.sound = .default
            content.categoryIdentifier = NotificationService.categoryID

            // Only identifiers travel in `userInfo`. The system keeps pending notifications in
            // its own unencrypted store, outside anything `SecureStore` can protect, so the
            // payload is resolved from the encrypted cache when the user actually clicks.
            // (Title and body are still there — the OS has to render them — so this narrows the
            // exposure rather than removing it.)
            if let idsData = try? JSONEncoder().encode(cluster.items.map(\.eventID)),
               let idsString = String(data: idsData, encoding: .utf8) {
                content.userInfo = [
                    NotificationService.eventIDsUserInfoKey: idsString
                ]
            }

            let trigger = UNTimeIntervalNotificationTrigger(
                timeInterval: timeInterval,
                repeats: false
            )
            let request = UNNotificationRequest(
                identifier: idPrefix + cluster.id,
                content: content,
                trigger: trigger
            )

            do {
                try await center.add(request)
            } catch {
                log.error("Failed to schedule notification for '\(cluster.anchorEvent.title)': \(error)")
            }
        }
    }
}

extension NotificationService: NotificationServicing {}
