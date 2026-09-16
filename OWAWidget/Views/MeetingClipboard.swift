import SwiftUI
import AppKit

/// Everything the UI copies about a meeting goes through here, so the list row, the timeline card,
/// the banner and the detail panel put the same text on the pasteboard.
@MainActor
enum MeetingClipboard {
    static func copy(_ string: String, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }

    static func copyTitle(of event: CalendarEvent) {
        copy(event.title)
    }

    static func copyLink(of event: CalendarEvent) {
        guard let url = event.joinURLForActions else { return }
        copy(url.absoluteString)
    }

    static func copySummary(of event: CalendarEvent, localization: LocalizationService) {
        copy(summary(of: event, localization: localization))
    }

    /// Plain-text invite for pasting into a chat: title, then date and time, then the join link.
    static func summary(of event: CalendarEvent, localization: LocalizationService) -> String {
        let formatter = DateFormatter()
        formatter.locale = localization.locale
        formatter.calendar = AppTimeZone.calendar
        formatter.timeZone = AppTimeZone.zone
        formatter.setLocalizedDateFormatFromTemplate("EEEEdMMMM")
        var when = formatter.string(from: event.startDate)
        if !event.isAllDay {
            when += ", \(localization.shortTime(event.startDate))–\(localization.shortTime(event.endDate))"
        }

        var lines = [event.title, when]
        if let url = event.joinURLForActions {
            lines.append(url.absoluteString)
        }
        return lines.joined(separator: "\n")
    }
}

/// Right-click menu shared by every place that shows a meeting.
private struct MeetingCopyMenuItems: View {
    let event: CalendarEvent
    let localization: LocalizationService

    var body: some View {
        Button(localization.tr("meeting.copy.title")) {
            MeetingClipboard.copyTitle(of: event)
        }
        if event.joinURLForActions != nil {
            Button(localization.tr("meeting.copy.link")) {
                MeetingClipboard.copyLink(of: event)
            }
        }
        Button(localization.tr(event.joinURLForActions != nil ? "meeting.copy.summary" : "meeting.copy.summary.nolink")) {
            MeetingClipboard.copySummary(of: event, localization: localization)
        }
    }
}

extension View {
    /// Localization is passed in rather than read from the environment: menu content is hosted
    /// outside the view hierarchy, and a missing environment object there is a crash, not a fallback.
    func meetingCopyContextMenu(_ event: CalendarEvent, localization: LocalizationService) -> some View {
        contextMenu {
            MeetingCopyMenuItems(event: event, localization: localization)
        }
    }
}
