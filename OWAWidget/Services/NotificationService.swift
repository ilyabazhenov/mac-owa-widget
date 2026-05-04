import Foundation
import UserNotifications
import os.log

actor NotificationService {
    static let categoryID = "MEETING_JOIN"
    static let actionID = "JOIN_MEETING"
    private let idPrefix = "owawidget."

    private let center = UNUserNotificationCenter.current()
    private let log = Logger(subsystem: "com.owawidget", category: "NotificationService")

    func setup() {
        let joinAction = UNNotificationAction(
            identifier: NotificationService.actionID,
            title: "Join",
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

    func scheduleNotifications(for events: [CalendarEvent], leadMinutes: Int) async {
        // Remove previously scheduled OWA Widget notifications
        let pending = await center.pendingNotificationRequests()
        let toRemove = pending.map(\.identifier).filter { $0.hasPrefix(idPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: toRemove)

        let now = Date()
        let lead = TimeInterval(leadMinutes * 60)

        for event in events where !event.isAllDay {
            let fireDate = event.startDate.addingTimeInterval(-lead)
            guard fireDate > now else { continue }

            let content = UNMutableNotificationContent()
            content.title = event.title
            content.body = buildBody(event: event, leadMinutes: leadMinutes)
            content.sound = .default
            content.categoryIdentifier = NotificationService.categoryID

            if let joinURL = event.joinURL {
                content.userInfo = [
                    "joinURL": joinURL.absoluteString,
                    "eventID": event.id
                ]
            }

            let trigger = UNTimeIntervalNotificationTrigger(
                timeInterval: fireDate.timeIntervalSinceNow,
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

    private func buildBody(event: CalendarEvent, leadMinutes: Int) -> String {
        let timeStr = shortTime(event.startDate)
        if event.hasJoinURL {
            return "Starts in \(leadMinutes) min at \(timeStr) · Tap Join to connect"
        } else {
            return "Starts in \(leadMinutes) min at \(timeStr)"
        }
    }

    private func shortTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f.string(from: date)
    }
}
