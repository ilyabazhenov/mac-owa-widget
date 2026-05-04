import Foundation
import UserNotifications
import os.log

struct NotificationLocalization: Sendable {
    let localeIdentifier: String
    let joinActionTitle: String
    let bodyWithJoinFormat: String
    let bodyWithoutJoinFormat: String

    static let english = NotificationLocalization(
        localeIdentifier: "en",
        joinActionTitle: "Join",
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

    func scheduleNotifications(
        for events: [CalendarEvent],
        leadMinutes: Int,
        localization: NotificationLocalization = .english
    ) async {
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
            content.body = buildBody(event: event, leadMinutes: leadMinutes, localization: localization)
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

    private func buildBody(
        event: CalendarEvent,
        leadMinutes: Int,
        localization: NotificationLocalization
    ) -> String {
        let locale = Locale(identifier: localization.localeIdentifier)
        let timeStr = shortTime(event.startDate, locale: locale)
        let minutes = localizedMinutes(leadMinutes, localeIdentifier: localization.localeIdentifier)
        if event.hasJoinURL {
            return String(format: localization.bodyWithJoinFormat, locale: locale, minutes, timeStr)
        } else {
            return String(format: localization.bodyWithoutJoinFormat, locale: locale, minutes, timeStr)
        }
    }

    private func shortTime(_ date: Date, locale: Locale) -> String {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        f.locale = locale
        return f.string(from: date)
    }

    private func localizedMinutes(_ count: Int, localeIdentifier: String) -> String {
        if localeIdentifier == "ru" {
            let mod10 = count % 10
            let mod100 = count % 100
            if mod10 == 1 && mod100 != 11 { return "\(count) минута" }
            if (2...4).contains(mod10) && !(12...14).contains(mod100) { return "\(count) минуты" }
            return "\(count) минут"
        }

        return count == 1 ? "\(count) minute" : "\(count) minutes"
    }
}
