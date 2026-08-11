import SwiftUI
import AppKit

/// Runs `action` when Esc is pressed while the view is on screen.
///
/// SwiftUI's `onExitCommand` only fires for a view inside the window's responder chain. That holds
/// for the search fields (a focused `TextField`), but the meeting detail card holds no focus and
/// its body is an `NSTextView` that consumes key events itself — so Esc never reached it.
/// A local event monitor sees the key whoever is first responder, and lives only as long as the
/// view does.
///
/// The monitor is app-wide, so `action` receives the event and decides whether the key was meant
/// for it: returning `false` lets Esc travel on to whichever window actually has focus.
private struct EscapeKeyMonitor: ViewModifier {
    let action: (NSEvent) -> Bool

    @State private var monitor: Any?

    private static let escapeKeyCode: UInt16 = 53

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard monitor == nil else { return }
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    guard event.keyCode == Self.escapeKeyCode, action(event) else { return event }
                    // Swallowed once handled: otherwise the key travels on and the responder chain
                    // acts on it a second time.
                    return nil
                }
            }
            .onDisappear {
                if let monitor {
                    NSEvent.removeMonitor(monitor)
                }
                monitor = nil
            }
    }
}

extension View {
    /// `action` returns `true` when it consumed the key.
    func onEscapeKey(perform action: @escaping (NSEvent) -> Bool) -> some View {
        modifier(EscapeKeyMonitor(action: action))
    }
}
