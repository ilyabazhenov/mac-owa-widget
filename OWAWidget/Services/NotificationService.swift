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

struct NotificationLocalization: Sendable {
    let localeIdentifier: String
    let joinActionTitle: String
    let dismissActionTitle: String
    let bodyWithJoinFormat: String
    let bodyWithoutJoinFormat: String

    static let english = NotificationLocalization(
        localeIdentifier: "en",
        joinActionTitle: "Join",
        dismissActionTitle: "Dismiss",
        bodyWithJoinFormat: "Starts in %@ at %@. Tap Join to connect",
        bodyWithoutJoinFormat: "Starts in %@ at %@"
    )
}

actor NotificationService {
    static let categoryID = "MEETING_JOIN"
    static let actionID = "JOIN_MEETING"
    private let idPrefix = "owawidget."
    static let itemsUserInfoKey = "meetingItems"

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
            content.title = MeetingReminderText.title(cluster: cluster, localeIdentifier: localization.localeIdentifier)
            content.body = MeetingReminderText.reminderBody(cluster: cluster, leadMinutes: leadMinutes, localization: localization)
            content.sound = .default
            content.categoryIdentifier = NotificationService.categoryID

            if let itemsData = try? JSONEncoder().encode(cluster.items),
               let itemsString = String(data: itemsData, encoding: .utf8) {
                content.userInfo = [
                    NotificationService.itemsUserInfoKey: itemsString
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
