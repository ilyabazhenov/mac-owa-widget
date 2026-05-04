import Foundation

// MARK: - Schedule (shared by system UN + in-app reminders)

enum MeetingReminderSchedule {
    /// Delay until the reminder should fire, or `nil` if the event should be skipped.
    static func deliveryDelay(
        event: CalendarEvent,
        leadMinutes: Int,
        from now: Date
    ) -> TimeInterval? {
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
}
