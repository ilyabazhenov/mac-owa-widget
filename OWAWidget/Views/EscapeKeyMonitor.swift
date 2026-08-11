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
/// The monitor is not window-scoped: the popover is the app's only window while it is open
/// (MenuBarExtra closes it as soon as focus moves elsewhere), so there is nothing else on screen
/// that could swallow an Esc meant for the card.
private struct EscapeKeyMonitor: ViewModifier {
    let action: () -> Void

    @State private var monitor: Any?

    private static let escapeKeyCode: UInt16 = 53

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard monitor == nil else { return }
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    guard event.keyCode == Self.escapeKeyCode else { return event }
                    action()
                    // Swallowed: without this the key would travel on and close the whole popover.
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
    func onEscapeKey(perform action: @escaping () -> Void) -> some View {
        modifier(EscapeKeyMonitor(action: action))
    }
}
