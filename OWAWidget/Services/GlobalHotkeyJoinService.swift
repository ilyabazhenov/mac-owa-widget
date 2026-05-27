import AppKit
import Foundation
import KeyboardShortcuts

@MainActor
final class GlobalHotkeyJoinService {
    static let shared = GlobalHotkeyJoinService()

    private var isStarted = false

    func start(calendarService: CalendarService) {
        guard !isStarted else { return }
        isStarted = true

        KeyboardShortcuts.onKeyUp(for: .joinMeeting) { [weak calendarService] in
            guard let calendarService else { return }
            guard calendarService.globalJoinHotkeyEnabled else { return }

            let now = Date()
            let candidates = GlobalHotkeyJoinAction.candidates(from: calendarService.events, now: now)

            guard !candidates.isEmpty else {
                let localization = LocalizationService()
                GlobalHotkeyFeedbackController.shared.showNoMeetingPanel(
                    message: localization.tr("join.hotkey.noMeeting")
                )
                return
            }

            if candidates.count == 1, let event = candidates.first {
                calendarService.openJoinURL(for: event, source: .globalShortcut)
                PostJoinDismissController.shared.dismissAfterJoin(context: .popoverContent)
                return
            }

            let items = candidates.map(MeetingReminderItem.init(event:))
            MeetingJoinSelectionController.shared.present(items: items) { selected in
                calendarService.openJoinURL(for: selected, source: .globalShortcut)
            }
        }
    }
}

