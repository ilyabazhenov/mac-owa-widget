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
        // Compute the smart-mode presentation once per render; icon/label/pulse/tooltip all derive
        // from it, so recomputing per accessor would run the formatter several times each tick.
        let smart = self.smart

        HStack(spacing: 4) {
            Image(systemName: iconName(smart))
                .imageScale(.medium)

            if let label = label(for: smart) {
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .frame(minWidth: 28, alignment: .trailing)
            }
        }
        .opacity(pulseOpacity)
        .background(MenuBarRightClickHandler(menu: buildContextMenu()))
        .onReceive(ticker) { now = $0 }
        .onChange(of: shouldPulse(smart)) { happening in
            if happening {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    pulseOpacity = 0.3
                }
            } else {
                withAnimation { pulseOpacity = 1.0 }
            }
        }
        .help(helpText(for: smart))
        .onAppear {
            logAppearance()
            KeyboardShortcuts.onKeyUp(for: .createMeeting) {
                NotificationCenter.default.post(name: .openCreateMeetingShortcut, object: nil)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openCreateMeetingShortcut)) { _ in
            // The shortcut stays registered regardless: it is a global hotkey, and unregistering
            // it per account state would leave the key silently bound to nothing elsewhere.
            guard service.supportsMeetingCreation else { return }
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "create-meeting")
        }
    }

    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu()

        if service.supportsMeetingCreation {
            menu.addItem(ClosureMenuItem(title: localization.tr("menu.new.meeting")) {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "create-meeting")
            })

            menu.addItem(.separator())
        }

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

    /// Smart-mode presentation, or `nil` when another display mode is active.
    private var smart: MenuBarSmartStatusFormatter.Presentation? {
        guard service.menuBarDisplayMode == .smart else { return nil }
        return MenuBarSmartStatusFormatter.presentation(
            events: service.events,
            now: now,
            calendar: AppTimeZone.calendar
        )
    }

    private func iconName(_ smart: MenuBarSmartStatusFormatter.Presentation?) -> String {
        // An actionable sync problem takes precedence over the "meeting in progress" icon:
        // if sync is broken the calendar data may be stale, so surfacing it matters more.
        if hasSyncProblem { return "calendar.badge.exclamationmark" }
        if let smart { return smart.category == .engaged ? "calendar.badge.clock" : "calendar" }
        return isHappeningNow ? "calendar.badge.clock" : "calendar"
    }

    /// Drives the pulse animation: in smart mode the formatter decides "act now / live"
    /// (imminent or in a meeting); otherwise fall back to the legacy "happening now" rule.
    private func shouldPulse(_ smart: MenuBarSmartStatusFormatter.Presentation?) -> Bool {
        if hasSyncProblem { return false }
        if let smart { return smart.pulse }
        return isHappeningNow
    }

    /// True for sync states that need the user to act (re-enter password, re-trust the server,
    /// approve a login host) or that hard-failed with no data. Soft states like `.offlineCached`
    /// are intentionally excluded — they already surface in the popover footer and shouldn't
    /// alarm the menu bar.
    ///
    /// Asks `blocksSync` rather than naming the cases. Spelling them out here once let a newly
    /// added blocking status suspend sync while the menu bar carried on showing a plain calendar
    /// icon, because nothing makes an `if case` chain fail when a case is added.
    private var hasSyncProblem: Bool {
        let status = service.syncStatus
        return status.blocksSync || status.isError
    }

    private var isHappeningNow: Bool {
        service.events.contains { $0.startDate <= now && $0.endDate > now }
    }

    private func label(for smart: MenuBarSmartStatusFormatter.Presentation?) -> String? {
        if let smart {
            switch smart.content {
            case .iconOnly: return nil
            case .duration(let text): return text
            case .relativeDays(let days): return "\(days)d"
            case .time(let date): return localization.shortTime(date)
            }
        }
        return MenuBarLabelFormatter.label(
            mode: service.menuBarDisplayMode,
            events: service.events,
            now: now,
            shortTimeFormatter: localization.shortTime,
            calendar: AppTimeZone.calendar
        )
    }

    private func helpText(for smart: MenuBarSmartStatusFormatter.Presentation?) -> String {
        // When sync needs attention, the tooltip explains what's wrong (e.g. "Invalid
        // password — update in Settings") so the exclamation icon is actionable on hover.
        if hasSyncProblem {
            return localization.syncStatusText(service.syncStatus)
        }
        if let smart { return smartTooltip(smart.tooltip) }
        let count = service.events.filter { $0.startDate.isToday }.count
        return count == 0
            ? localization.tr("menubar.no.meetings.today")
            : localization.tr("menubar.meetings.today", localization.meetings(count))
    }

    /// Turns the smart formatter's semantic tooltip into a localized, timezone-aware string.
    /// This is where the "fine" detail (has-link, overlap, free-until, tomorrow) surfaces —
    /// deliberately kept out of the narrow menu bar label itself.
    private func smartTooltip(_ tooltip: MenuBarSmartStatusFormatter.Tooltip) -> String {
        let noLink = localization.tr("menubar.smart.tip.no.link")
        switch tooltip {
        case .inMeeting(let remaining, let hasJoinURL):
            let base = localization.tr("menubar.smart.tip.in.meeting", localization.minutes(remaining))
            return hasJoinURL ? base : "\(base) · \(noLink)"
        case .overlap(let count):
            return localization.tr("menubar.smart.tip.overlap", localization.meetings(count))
        case .joinNow(let hasJoinURL):
            return hasJoinURL ? localization.tr("menubar.smart.tip.join.now") : noLink
        case .soon(let start, let hasJoinURL):
            let base = localization.tr("menubar.smart.tip.soon", localization.shortTime(start))
            return hasJoinURL ? base : "\(base) · \(noLink)"
        case .freeUntil(let start):
            return localization.tr("menubar.smart.tip.free.until", localization.shortTime(start))
        case .nextDay(let start):
            return localization.tr("menubar.smart.tip.next.day", localization.shortTime(start))
        case .laterDays(let count):
            return localization.tr("menubar.smart.tip.later", localization.days(count))
        case .nothingUpcoming:
            return localization.tr("menubar.no.meetings.today")
        }
    }
}
