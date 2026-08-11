import SwiftUI
import AppKit

/// Opaque monitor token. `NSEvent`'s monitor object is only ever handed back to AppKit, so moving
/// it across threads is safe even though its type carries no such guarantee.
private struct EventMonitorToken: @unchecked Sendable {
    let value: Any
}

/// Owns the local key monitor. A reference type on purpose: the handler lives in a mutable
/// property that every render refreshes (a monitor closure captured once would keep answering from
/// the view snapshot that installed it), and `deinit` can act as a last-resort teardown.
private final class EscapeKeyMonitorBox: ObservableObject {
    var action: (NSEvent) -> Bool = { _ in false }

    private var monitor: Any?
    private static let escapeKeyCode: UInt16 = 53

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == Self.escapeKeyCode, self.action(event) else { return event }
            // Swallowed once handled: otherwise the key travels on and the responder chain
            // acts on it a second time.
            return nil
        }
    }

    func remove() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
    }

    /// Backstop for a view that never receives `onDisappear`. Releasing a `@StateObject` normally
    /// happens on the main thread, but that is not a contract, and `removeMonitor` is AppKit.
    deinit {
        guard let monitor else { return }
        let token = EventMonitorToken(value: monitor)
        if Thread.isMainThread {
            NSEvent.removeMonitor(token.value)
        } else {
            DispatchQueue.main.async { NSEvent.removeMonitor(token.value) }
        }
    }
}

/// Runs `action` when Esc is pressed while the view is on screen.
///
/// SwiftUI's `onExitCommand` only fires for a view inside the window's responder chain. That holds
/// for the search fields (a focused `TextField`), but the meeting detail card holds no focus and
/// its body is an `NSTextView` that consumes key events itself — so Esc never reached it.
/// A local event monitor sees the key whoever is first responder.
///
/// The monitor is app-wide, so `action` receives the event and decides whether the key was meant
/// for it: returning `false` lets Esc travel on to whichever window actually has focus. It is also
/// installed only while the view is on screen — keeping an app-wide key hook alive for a popover
/// that is closed would widen the interception window for no reason.
private struct EscapeKeyMonitor: ViewModifier {
    let action: (NSEvent) -> Bool

    @StateObject private var box = EscapeKeyMonitorBox()

    func body(content: Content) -> some View {
        // Assigning a plain (non-published) property during an update publishes nothing, so this
        // cannot feed back into the render loop.
        box.action = action
        return content
            .onAppear { box.install() }
            .onDisappear { box.remove() }
    }
}

extension View {
    /// `action` returns `true` when it consumed the key.
    func onEscapeKey(perform action: @escaping (NSEvent) -> Bool) -> some View {
        modifier(EscapeKeyMonitor(action: action))
    }
}
