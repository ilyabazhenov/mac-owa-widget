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
/// so the app that was in front gets its focus back right after.
///
/// What the popover does on opening still happens — a colleagues refresh when it is stale and an
/// inbox check, both of which launch triggers anyway — and nothing in it marks anything as seen.
/// The inbox panel beside the popover stays hidden throughout (`isPrewarming`).
@MainActor
enum PopoverPrewarmer {
    /// While true the popover is open only to be built: the inbox panel must not come up.
    private(set) static var isPrewarming = false
    private static var didRun = false

    /// Seconds after the menu bar icon appears: past launch work, still well before most first clicks.
    static let delayAfterLaunch: TimeInterval = 4

    static func scheduleAfterLaunch() {
        DispatchQueue.main.asyncAfter(deadline: .now() + delayAfterLaunch) {
            MainActor.assumeIsolated { prewarmIfNeeded() }
        }
    }

    static func prewarmIfNeeded() {
        guard !didRun else { return }
        didRun = true
        // The user got there first: the tree is already built.
        guard PostJoinDismissController.shared.registeredPopoverWindow == nil else { return }
        // Something of ours is on screen (Settings, a reminder): leave the app alone.
        guard !NSApp.windows.contains(where: { $0.isVisible && $0.level != .statusBar && !$0.className.contains("NSStatusBar") }) else {
            DiagnosticLog.event("Popover prewarm skipped: a window is open")
            return
        }
        guard let button = MenuBarPopoverOpener.statusButton() else { return }

        let frontmost = NSWorkspace.shared.frontmostApplication
        let started = DispatchTime.now().uptimeNanoseconds
        let windowsBefore = Set(NSApp.windows.map(ObjectIdentifier.init))
        isPrewarming = true
        defer { isPrewarming = false }

        button.performClick(nil)
        // SwiftUI makes the window inside the click; the registrar only hears of it later, so the
        // window is found by being new and visible rather than through the registrar.
        let popover = NSApp.windows.first {
            !windowsBefore.contains(ObjectIdentifier($0)) && $0.isVisible && !$0.className.contains("NSStatusBar")
        }
        guard let popover else {
            DiagnosticLog.event("Popover prewarm: no popover window after the click")
            return
        }
        popover.alphaValue = 0
        popover.orderOut(nil)
        popover.close()
        // Visible again for the user's own first click.
        DispatchQueue.main.async {
            MainActor.assumeIsolated { popover.alphaValue = 1 }
        }
        if let frontmost, frontmost != NSRunningApplication.current {
            frontmost.activate()
        }
        let milliseconds = (DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        DiagnosticLog.event("Popover prewarmed ms=\(milliseconds)")
    }
}
