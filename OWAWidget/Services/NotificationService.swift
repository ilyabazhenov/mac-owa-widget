import Foundation
import UserNotifications
import os.log

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

    private let center = UNUserNotificationCenter.current()
    private let log = Logger(subsystem: "com.owawidget", category: "NotificationService")

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

        for event in events where !event.isAllDay {
            guard let timeInterval = MeetingReminderSchedule.deliveryDelay(
                event: event,
                leadMinutes: leadMinutes,
                from: now
            ) else { continue }

            let content = UNMutableNotificationContent()
            content.title = event.title
            content.body = MeetingReminderText.reminderBody(
                event: event,
                leadMinutes: leadMinutes,
                localization: localization
            )
            content.sound = .default
            content.categoryIdentifier = NotificationService.categoryID

            if let joinURL = event.joinURL {
                content.userInfo = [
                    "joinURL": joinURL.absoluteString,
                    "eventID": event.id
                ]
            }

            let trigger = UNTimeIntervalNotificationTrigger(
                timeInterval: timeInterval,
                repeats: false
            )
            let request = UNNotificationRequest(
                identifier: idPrefix + event.id,
                content: content,
                trigger: trigger
            )

            do {
                try await center.add(request)
            } catch {
                log.error("Failed to schedule notification for '\(event.title)': \(error)")
            }
        }
    }
}

extension NotificationService: NotificationServicing {}
