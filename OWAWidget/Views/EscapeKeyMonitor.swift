import SwiftUI
import AppKit

/// Owns the local key monitor. A reference type on purpose: `deinit` guarantees the monitor is
/// removed even if SwiftUI never delivers `onDisappear`, and the handler lives in a mutable
/// property that every render refreshes — a monitor closure captured once would otherwise keep
/// answering from the view snapshot that installed it.
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

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
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
/// for it: returning `false` lets Esc travel on to whichever window actually has focus.
private struct EscapeKeyMonitor: ViewModifier {
    let action: (NSEvent) -> Bool

    @StateObject private var box = EscapeKeyMonitorBox()

    func body(content: Content) -> some View {
        // Assigning a plain (non-published) property during an update publishes nothing, so this
        // cannot feed back into the render loop.
        box.action = action
        return content.onAppear { box.install() }
    }
}

extension View {
    /// `action` returns `true` when it consumed the key.
    func onEscapeKey(perform action: @escaping (NSEvent) -> Bool) -> some View {
        modifier(EscapeKeyMonitor(action: action))
    }
}
