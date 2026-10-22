import KeyboardShortcuts
import SwiftUI

struct MenuBarLabelView: View {
    @EnvironmentObject var service: CalendarService
    @EnvironmentObject private var mail: MailService
    @EnvironmentObject private var localization: LocalizationService
    @Environment(\.openWindow) private var openWindow
    @State private var pulseOpacity: Double = 1.0
    /// What the label showed when the clock last looked. The clock ticks every second, but every
    /// formatter here counts whole minutes: redrawing the status item each second re-rendered the
    /// same picture (a main-thread turn of ~17 ms, every second, all day). The tick now compares
    /// and redraws only when something visible changed.
    @State private var shown: Presentation?

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// Everything the label puts on screen; two equal values draw the same status item.
    struct Presentation: Equatable {
        let icon: String
        let label: String?
        let pulse: Bool
        let help: String
    }

    var body: some View {
        let _ = PerfProbe.body("MenuBarLabelView")
        // Always the current time, never a stored one: the body also runs when the calendar or
        // mail changes, and a time kept from the last visible change could be minutes old.
        let visible = presentation(at: Date())
        // Read so that the tick's write redraws the label: SwiftUI skips a body that does not
        // depend on the state that changed.
        let _ = shown

        HStack(spacing: 4) {
            Image(systemName: visible.icon)
                .imageScale(.medium)

            // The invitation count rides inside the one Text: a status item renders a single image
            // and a single text, and silently drops any further view put in the label.
            if let label = visible.label {
                Text(label)
                    .font(.app(.body, weight: .medium))
                    .monospacedDigit()
                    .frame(minWidth: 28, alignment: .trailing)
            }
        }
        .opacity(pulseOpacity)
        // Built when the menu opens, not on every redraw of the label.
        .background(MenuBarRightClickHandler(makeMenu: buildContextMenu))
        .onReceive(ticker) { date in
            let current = presentation(at: date)
            if current != shown { shown = current }
        }
        .onChange(of: visible.pulse) { happening in
            if happening {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    pulseOpacity = 0.3
                }
            } else {
                withAnimation { pulseOpacity = 1.0 }
            }
        }
        .help(visible.help)
        // Compose and "show this conversation" can be asked for from anywhere (the popover, an MCP
        // panel); the label is always on screen, so it is the one place that opens the windows.
        .onChange(of: mail.composeRequest?.id) { id in
            guard id != nil else { return }
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "mail-compose")
        }
        .onChange(of: mail.openRequest) { request in
            guard request != nil else { return }
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "mail")
        }
        .onAppear {
            logAppearance()
            PopoverPrewarmer.scheduleAfterLaunch()
            KeyboardShortcuts.onKeyUp(for: .createMeeting) {
                NotificationCenter.default.post(name: .openCreateMeetingShortcut, object: nil)
            }
            KeyboardShortcuts.onKeyUp(for: .openMail) {
                NotificationCenter.default.post(name: .openMailShortcut, object: nil)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openCreateMeetingShortcut)) { _ in
            // The shortcut stays registered regardless: it is a global hotkey, and unregistering
            // it per account state would leave the key silently bound to nothing elsewhere.
            guard service.supportsMeetingCreation else { return }
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "create-meeting")
        }
        .onReceive(NotificationCenter.default.publisher(for: .openMailShortcut)) { _ in
            // Registered regardless too: with mail off the key just does nothing.
            guard mail.isAvailable else { return }
            openMailWindow()
        }
    }

    private func openMailWindow() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "mail")
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

        // The way to mail for those who keep it out of the popover.
        if mail.isAvailable {
            menu.addItem(ClosureMenuItem(title: localization.tr("mail.popover.open")) {
                openMailWindow()
            })
            menu.addItem(ClosureMenuItem(title: localization.tr("mail.compose.title.new")) {
                mail.compose(MailComposeRequest(kind: .new, original: nil, to: [], cc: [], subject: "", body: ""))
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "mail-compose")
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

    /// The label as it should look at `now`. The smart-mode presentation is computed once and
    /// icon, label, pulse and tooltip all derive from it.
    private func presentation(at now: Date) -> Presentation {
        let smart = smart(at: now)
        let pendingInvitations = service.menuBarInvitationCount
        let unreadMail = mail.menuBarUnreadCount
        return Presentation(
            icon: iconName(smart, now: now),
            label: Self.composedLabel(label(for: smart, now: now), pendingInvitations: pendingInvitations, unreadMail: unreadMail),
            pulse: shouldPulse(smart, now: now),
            help: helpText(for: smart, pendingInvitations: pendingInvitations, unreadMail: unreadMail)
        )
    }

    /// Smart-mode presentation, or `nil` when another display mode is active.
    private func smart(at now: Date) -> MenuBarSmartStatusFormatter.Presentation? {
        guard service.menuBarDisplayMode == .smart else { return nil }
        return MenuBarSmartStatusFormatter.presentation(
            events: service.events,
            now: now,
            calendar: AppTimeZone.calendar
        )
    }

    private func iconName(_ smart: MenuBarSmartStatusFormatter.Presentation?, now: Date) -> String {
        // An actionable sync problem takes precedence over the "meeting in progress" icon:
        // if sync is broken the calendar data may be stale, so surfacing it matters more.
        if hasSyncProblem { return "calendar.badge.exclamationmark" }
        if let smart { return smart.category == .engaged ? "calendar.badge.clock" : "calendar" }
        return isHappeningNow(at: now) ? "calendar.badge.clock" : "calendar"
    }

    /// Drives the pulse animation: in smart mode the formatter decides "act now / live"
    /// (imminent or in a meeting); otherwise fall back to the legacy "happening now" rule.
    private func shouldPulse(_ smart: MenuBarSmartStatusFormatter.Presentation?, now: Date) -> Bool {
        if hasSyncProblem { return false }
        if let smart { return smart.pulse }
        return isHappeningNow(at: now)
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

    private func isHappeningNow(at now: Date) -> Bool {
        service.events.contains { $0.startDate <= now && $0.endDate > now }
    }

    private func label(for smart: MenuBarSmartStatusFormatter.Presentation?, now: Date) -> String? {
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

    /// Appends "✉︎N" for new invitations awaiting an answer. The variation selector keeps the
    /// envelope a monochrome text glyph, so it takes the menu bar's tint like the rest of the label.
    ///
    /// Unread mail rides along as "@N": the envelope already means invitations here.
    static func composedLabel(_ label: String?, pendingInvitations: Int, unreadMail: Int = 0) -> String? {
        var badges: [String] = []
        if pendingInvitations > 0 { badges.append("\u{2709}\u{FE0E}\(pendingInvitations)") }
        if unreadMail > 0 { badges.append("@\(unreadMail)") }
        guard !badges.isEmpty else { return label }
        let badge = badges.joined(separator: " ")
        guard let label, !label.isEmpty else { return badge }
        return "\(label) \(badge)"
    }

    private func helpText(for smart: MenuBarSmartStatusFormatter.Presentation?, pendingInvitations: Int, unreadMail: Int) -> String {
        var lines = [helpText(for: smart)]
        if pendingInvitations > 0 { lines.append(localization.tr("menubar.invitations.pending", pendingInvitations)) }
        if unreadMail > 0 { lines.append(localization.tr("menubar.mail.unread", unreadMail)) }
        return lines.joined(separator: "\n")
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
            let base = localization.tr("menubar.smart.tip.in.meeting", localization.compactDuration(minutes: remaining))
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
