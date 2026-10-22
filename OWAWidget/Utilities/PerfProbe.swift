import AppKit
import Foundation
import os

/// Where the main thread's time goes. Signposts show up in Instruments under Points of Interest;
/// a turn of the main run loop that keeps the app busy for long is written to `diagnostic.log`
/// with the views whose `body` ran in it, so a freeze a user feels leaves a line saying what
/// redrew. Only names and counts are logged, never content.
enum PerfProbe {
    static let signposter = OSSignposter(subsystem: "com.owawidget", category: .pointsOfInterest)

    /// A turn of the run loop longer than this is a hitch the user can feel (three frames).
    static let defaultSlowTurnMilliseconds: Double = 50
    /// Lowers the threshold for a closer look at one machine, e.g. to 16 ms (one frame):
    /// `defaults write com.owawidget.MacOwaWidget perfSlowTurnMs 16`, then relaunch. With it set,
    /// every such turn gets its own line.
    static let thresholdDefaultsKey = "perfSlowTurnMs"
    /// At most one line per this many seconds by default; the turns in between are counted into it.
    private static let logInterval: TimeInterval = 0.5

    @MainActor private static var slowTurnMilliseconds = defaultSlowTurnMilliseconds
    @MainActor private static var limitsLines = true

    @MainActor private static var bodies: [String: Int] = [:]
    @MainActor private static var marks: [String: Int] = [:]
    @MainActor private static var turnStart: UInt64 = 0
    @MainActor private static var lastLogged: Date = .distantPast
    @MainActor private static var suppressed = 0
    @MainActor private static var observer: CFRunLoopObserver?

    /// Counts one evaluation of a view's `body` in the current run loop turn.
    /// Use as `let _ = PerfProbe.body("Name")` at the top of `body`.
    @MainActor
    static func body(_ name: StaticString) {
        signposter.emitEvent(name)
        bodies["\(name)", default: 0] += 1
    }

    /// Notes something that happened in this turn (a swipe's outcome, a list change), so a slow
    /// turn's line says what set it off.
    @MainActor
    static func mark(_ name: String) {
        signposter.emitEvent("mark", "\(name, privacy: .public)")
        marks[name, default: 0] += 1
    }

    /// Times `work` as a signpost interval.
    @MainActor
    static func interval<T>(_ name: StaticString, _ work: () throws -> T) rethrows -> T {
        let state = signposter.beginInterval(name)
        defer { signposter.endInterval(name, state) }
        return try work()
    }

    /// Watches the main run loop: from waking up to going back to sleep, after Core Animation's
    /// commit, so the time includes layout and drawing of what the turn changed.
    @MainActor
    static func startWatchingMainRunLoop() {
        guard observer == nil else { return }
        let custom = UserDefaults.standard.double(forKey: thresholdDefaultsKey)
        if custom > 0 {
            slowTurnMilliseconds = custom
            limitsLines = false
            DiagnosticLog.event("Perf watching main turns over \(custom) ms")
        }
        let activities = CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue
        let observer = CFRunLoopObserverCreateWithHandler(nil, activities, true, CFIndex.max) { _, activity in
            MainActor.assumeIsolated {
                if activity == .afterWaiting {
                    beginTurn()
                } else {
                    endTurn()
                }
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
        #if PERF_HARNESS
        startHarness()
        #endif
    }

    #if PERF_HARNESS
    /// The distributed notification a measuring script posts, with `open` or `close` as its object.
    static let harnessNotification = Notification.Name("com.owawidget.perf.popover")
    /// Posted in the app for `next` and `prev`, with the day step as its object; the popover pages.
    static let harnessStepDay = Notification.Name("com.owawidget.perf.stepDay")
    @MainActor private static var harnessObserver: NSObjectProtocol?

    /// Opens and closes the popover on request from outside, so two builds can be compared by
    /// their `Perf slow main turn` lines over the same sequence of opens. Any process may post a
    /// distributed notification — and with it click buttons in the popover (an RSVP is a real
    /// reply in Exchange) — so this exists only in builds made with `-Xswiftc -DPERF_HARNESS` for
    /// measuring. Not in debug builds: `make run` and `make bundle` build debug, and that is the
    /// copy used day to day.
    @MainActor
    private static func startHarness() {
        guard harnessObserver == nil else { return }
        harnessObserver = DistributedNotificationCenter.default().addObserver(
            forName: harnessNotification, object: nil, queue: .main
        ) { note in
            let action = note.object as? String ?? ""
            MainActor.assumeIsolated {
                mark("harness.\(action)")
                switch action {
                case "open": MenuBarPopoverOpener.open()
                case "close": PostJoinDismissController.shared.dismissPopover()
                case let command where command.hasPrefix("click:") || command.hasPrefix("rclick:") || command.hasPrefix("rdown:") || command.hasPrefix("kclick:") || command.hasPrefix("kdown:"):
                    sendMouse(command)
                case let command where command.hasPrefix("key:"):
                    sendKey(command)
                case "authblock", "clearevents":
                    NotificationCenter.default.post(name: harnessForceAuthBlock, object: action)
                case "frontmost":
                    DiagnosticLog.event("Harness frontmost=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil")")
                case "next", "prev":
                    NotificationCenter.default.post(name: harnessStepDay, object: action == "next" ? 1 : -1)
                default: break
                }
            }
        }
    }

    /// Posted in the app for `authblock` (a debug build latches the auth breaker) and `clearevents`
    /// (drops the events held in memory until the next sync, for the empty error state); see PopoverView.
    static let harnessForceAuthBlock = Notification.Name("com.owawidget.perf.authBlock")

    /// `click:x,y` / `rclick:x,y` / `rdown:x,y` (press only, leaves a menu open): a mouse click at a
    /// point of the popover, from its top-left corner; `kclick:x,y` clicks the key window instead.
    @MainActor
    private static func sendMouse(_ command: String) {
        let target = command.hasPrefix("kclick:") || command.hasPrefix("kdown:") ? NSApp.keyWindow : PostJoinDismissController.shared.registeredPopoverWindow
        guard let window = target, window.isVisible else { return }
        let parts = command.split(separator: ":")[1].split(separator: ",").compactMap { Double($0) }
        guard parts.count == 2 else { return }
        let point = NSPoint(x: parts[0], y: window.frame.height - parts[1])
        let types: [NSEvent.EventType] = switch command.split(separator: ":")[0] {
        case "rclick": [.rightMouseDown, .rightMouseUp]
        case "rdown": [.rightMouseDown]
        case "kdown": [.leftMouseDown]
        default: [.leftMouseDown, .leftMouseUp]
        }
        for type in types {
            if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                NSApp.postEvent(event, atStart: false)
            }
        }
    }

    /// `key:cmdq` or `key:esc`: a key press sent to the popover the way the keyboard would.
    @MainActor
    private static func sendKey(_ command: String) {
        let window = PostJoinDismissController.shared.registeredPopoverWindow
        let (keyCode, characters, flags): (UInt16, String, NSEvent.ModifierFlags) = switch command {
        case "key:cmdq": (12, "q", .command)
        case "key:esc": (53, "\u{1b}", [])
        case "key:down": (125, "\u{F701}", [])
        case "key:up": (126, "\u{F700}", [])
        case "key:return": (36, "\r", [])
        default: (0, "", [])
        }
        guard !characters.isEmpty, let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window?.windowNumber ?? 0, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
        ) else { return }
        NSApp.postEvent(event, atStart: false)
    }
    #endif

    @MainActor
    private static func beginTurn() {
        turnStart = DispatchTime.now().uptimeNanoseconds
    }

    @MainActor
    private static func endTurn() {
        defer {
            bodies.removeAll(keepingCapacity: true)
            marks.removeAll(keepingCapacity: true)
            turnStart = 0
        }
        guard turnStart != 0 else { return }
        let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - turnStart) / 1_000_000
        guard milliseconds >= slowTurnMilliseconds else { return }
        let now = Date()
        guard !limitsLines || now.timeIntervalSince(lastLogged) >= logInterval else {
            suppressed += 1
            return
        }
        lastLogged = now
        var line = "Perf slow main turn ms=\(Int(milliseconds.rounded()))"
        if !marks.isEmpty { line += " marks=[\(counted(marks))]" }
        line += " bodies=[\(counted(bodies))]"
        if suppressed > 0 { line += " +\(suppressed) more slow" }
        suppressed = 0
        DiagnosticLog.event(line)
    }

    private static func counted(_ counts: [String: Int]) -> String {
        counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map { "\($0.key)×\($0.value)" }
            .joined(separator: " ")
    }
}
