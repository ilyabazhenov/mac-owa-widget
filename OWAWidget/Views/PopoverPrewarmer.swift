import AppKit

/// Builds the popover once, unseen, soon after launch, so the user's first click opens it as
/// fast as every later one.
///
/// SwiftUI keeps the popover's view tree alive between openings, so only the very first opening
/// pays for building and laying out the whole tree: 200–330 ms on the main thread against
/// 20–45 ms for every later one. With the prewarm, the first click took 34–75 ms over three cold
/// launches; the prewarm itself takes 160–200 ms, unseen (release builds, 2026-10-22). The popover is a `MenuBarExtra`
/// window, which SwiftUI creates on the first click and offers no way to make ahead of time.
/// So the prewarm clicks the status item itself with the window made fully transparent, and
/// closes it again in the same turn of the run loop: nothing reaches the screen, and no key or
/// mouse event can be delivered to the window while it is open. The click makes the app active,
/// so the app that was in front gets its focus back right after, and the prewarm waits for the
/// keyboard and mouse to be still first, so no typing lands in the moment between.
///
/// What the popover does on opening still happens — a colleagues refresh when it is stale and an
/// inbox check, both of which launch triggers anyway — and nothing in it marks anything as seen.
/// The inbox panel beside the popover stays hidden throughout (`isPrewarming`).
@MainActor
enum PopoverPrewarmer {
    /// While true the popover is open only to be built: the inbox panel must not come up.
    private(set) static var isPrewarming = false
    private static var didRun = false
    private static var isScheduled = false

    /// Seconds after the menu bar icon appears: past launch work, still well before most first clicks.
    static let delayAfterLaunch: TimeInterval = 4
    /// The keyboard and mouse must have been still this long. The prewarm makes the app active for
    /// a moment, and keys typed meanwhile in the app in front would be lost.
    static let requiredIdleSeconds: TimeInterval = 2
    static let retryInterval: TimeInterval = 2
    /// Gives up after this many busy checks (about a minute): the first click then pays as before.
    static let maxAttempts = 30

    static func scheduleAfterLaunch() {
        guard !isScheduled else { return }
        isScheduled = true
        schedule(after: delayAfterLaunch, attempt: 1)
    }

    private static func schedule(after delay: TimeInterval, attempt: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            MainActor.assumeIsolated { prewarmIfNeeded(attempt: attempt) }
        }
    }

    /// Seconds since the last key press, click or pointer move in the session.
    private static var secondsSinceLastInput: TimeInterval {
        // `kCGAnyInputEventType`; reading it needs no permission.
        guard let anyInput = CGEventType(rawValue: ~0) else { return .infinity }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }

    static func prewarmIfNeeded(attempt: Int = 1) {
        guard !didRun else { return }
        // The user got there first: the tree is already built.
        guard PostJoinDismissController.shared.registeredPopoverWindow == nil else {
            didRun = true
            return
        }
        // Something of ours is on screen (Settings, a reminder): leave the app alone for now.
        let ourWindowOpen = NSApp.windows.contains { $0.isVisible && !$0.className.contains("NSStatusBar") }
        // No status item yet (the menu bar still laying out at login, or the item hidden behind
        // the notch): try again later like any other busy moment.
        let button = MenuBarPopoverOpener.statusButton()
        if ourWindowOpen || button == nil || secondsSinceLastInput < requiredIdleSeconds {
            if attempt < maxAttempts {
                schedule(after: retryInterval, attempt: attempt + 1)
            } else {
                didRun = true
                DiagnosticLog.event("Popover prewarm skipped: windowOpen=\(ourWindowOpen) statusItem=\(button != nil)")
            }
            return
        }
        guard let button else { return }
        didRun = true

        let frontmost = NSWorkspace.shared.frontmostApplication
        let started = DispatchTime.now().uptimeNanoseconds
        // By visibility, not by identity: SwiftUI may make the window on this click or have made
        // it earlier and only show it now. Whatever the click brought on screen goes away again.
        let visibleBefore = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
        isPrewarming = true
        defer {
            isPrewarming = false
            // Whatever happened above, the app that was in front gets its focus back; with none
            // in front (right after login) the app steps back, so typing does not land in an app
            // with no window.
            if let frontmost, frontmost != NSRunningApplication.current {
                frontmost.activate()
            } else {
                NSApp.deactivate()
            }
        }

        button.performClick(nil)
        let shown = NSApp.windows.filter {
            $0.isVisible && !visibleBefore.contains(ObjectIdentifier($0)) && !$0.className.contains("NSStatusBar")
        }
        if shown.isEmpty {
            // Nothing found to hide: close the popover the way the app always does, and if it is
            // still up, click the status item again — that toggles it shut.
            PostJoinDismissController.shared.dismissPopover()
            if PostJoinDismissController.shared.registeredPopoverWindow?.isVisible == true {
                button.performClick(nil)
            }
            DiagnosticLog.event("Popover prewarm: no window came up on the click")
            return
        }
        for window in shown {
            window.alphaValue = 0
            window.orderOut(nil)
            window.close()
        }
        // Visible again for the user's own first click.
        DispatchQueue.main.async {
            MainActor.assumeIsolated { shown.forEach { $0.alphaValue = 1 } }
        }
        let milliseconds = (DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        DiagnosticLog.event("Popover prewarmed ms=\(milliseconds) attempt=\(attempt)")
    }
}
