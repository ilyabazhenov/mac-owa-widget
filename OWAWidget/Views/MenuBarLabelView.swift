import KeyboardShortcuts
import SwiftUI

struct MenuBarLabelView: View {
    @EnvironmentObject var service: CalendarService
    @EnvironmentObject private var localization: LocalizationService
    @Environment(\.openWindow) private var openWindow
    @State private var pulseOpacity: Double = 1.0
    @State private var now: Date = .init()

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: iconName)
                .imageScale(.medium)

            if let label = countdownLabel {
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .frame(minWidth: 28, alignment: .trailing)
            }
        }
        .opacity(pulseOpacity)
        .background(MenuBarRightClickHandler(menu: buildContextMenu()))
        .onReceive(ticker) { now = $0 }
        .onChange(of: isHappeningNow) { happening in
            if happening {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    pulseOpacity = 0.3
                }
            } else {
                withAnimation { pulseOpacity = 1.0 }
            }
        }
        .help(helpText)
        .onAppear {
            logAppearance()
            KeyboardShortcuts.onKeyUp(for: .createMeeting) {
                NotificationCenter.default.post(name: .openCreateMeetingShortcut, object: nil)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openCreateMeetingShortcut)) { _ in
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "create-meeting")
        }
    }

    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu()

        menu.addItem(ClosureMenuItem(title: localization.tr("menu.new.meeting")) {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "create-meeting")
        })

        menu.addItem(.separator())

        menu.addItem(ClosureMenuItem(title: localization.tr("popover.sync.now")) {
            service.syncNow()
        })

        menu.addItem(ClosureMenuItem(title: localization.tr("popover.settings") + "…") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "settings")
        })

        menu.addItem(.separator())

        menu.addItem(ClosureMenuItem(title: localization.tr("menu.copy.diagnostics")) {
            DiagnosticLog.copyReportToClipboard()
        })

        menu.addItem(.separator())

        menu.addItem(ClosureMenuItem(title: localization.tr("popover.quit")) {
            NSApplication.shared.terminate(nil)
        })

        return menu
    }

    private func logAppearance() {
        let screen = NSScreen.main
        let size = screen.map { "\(Int($0.frame.width))x\(Int($0.frame.height))" } ?? "n/a"
        let notch = screen.map { $0.safeAreaInsets.top > 0 ? "yes" : "no" } ?? "n/a"
        DiagnosticLog.event(
            "MenuBarLabel appeared screen=\(size) notch=\(notch) mode=\(service.menuBarDisplayMode.rawValue) accounts=\(service.accounts.count)"
        )
    }

    private var iconName: String {
        // An actionable sync problem takes precedence over the "meeting in progress" icon:
        // if sync is broken the calendar data may be stale, so surfacing it matters more.
        if hasSyncProblem { return "calendar.badge.exclamationmark" }
        return isHappeningNow ? "calendar.badge.clock" : "calendar"
    }

    /// True for sync states that need the user to act (re-enter password, re-trust the server)
    /// or that hard-failed with no data. Soft states like `.offlineCached` are intentionally
    /// excluded — they already surface in the popover footer and shouldn't alarm the menu bar.
    private var hasSyncProblem: Bool {
        let status = service.syncStatus
        return status.isAuthenticationRequired || status.isCertificateTrustRequired || status.isError
    }

    private var isHappeningNow: Bool {
        service.events.contains { $0.startDate <= now && $0.endDate > now }
    }

    private var countdownLabel: String? {
        MenuBarLabelFormatter.label(
            mode: service.menuBarDisplayMode,
            events: service.events,
            now: now,
            shortTimeFormatter: localization.shortTime,
            calendar: AppTimeZone.calendar
        )
    }

    private var helpText: String {
        // When sync needs attention, the tooltip explains what's wrong (e.g. "Invalid
        // password — update in Settings") so the exclamation icon is actionable on hover.
        if hasSyncProblem {
            return localization.syncStatusText(service.syncStatus)
        }
        let count = service.events.filter { $0.startDate.isToday }.count
        return count == 0
            ? localization.tr("menubar.no.meetings.today")
            : localization.tr("menubar.meetings.today", localization.meetings(count))
    }
}
