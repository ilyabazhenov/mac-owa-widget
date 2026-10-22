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
    }

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
