import AppKit
import SwiftUI

@MainActor
final class ClosureMenuItem: NSMenuItem {
    private let closure: @MainActor () -> Void

    init(title: String, closure: @escaping @MainActor () -> Void) {
        self.closure = closure
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        self.target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { closure() }
}

struct MenuBarRightClickHandler: NSViewRepresentable {
    /// Called on each right click, so the menu reflects the state at that moment.
    let makeMenu: @MainActor () -> NSMenu

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.makeMenu = makeMenu
        context.coordinator.startIfNeeded()
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator {
        var makeMenu: (@MainActor () -> NSMenu)?
        private var monitor: Any?

        func startIfNeeded() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
                // NSStatusBarWindow runs at .statusBar level — reliable way to identify our icon
                guard let self, event.window?.level == .statusBar else { return event }
                self.showMenu(for: event)
                return nil
            }
        }

        func stop() {
            if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        }

        private func showMenu(for event: NSEvent) {
            guard let makeMenu, let contentView = event.window?.contentView else { return }
            // Local event monitors run on the main thread, where the event and view live too.
            nonisolated(unsafe) let mainEvent = event
            nonisolated(unsafe) let mainView = contentView
            MainActor.assumeIsolated {
                NSMenu.popUpContextMenu(makeMenu(), with: mainEvent, for: mainView)
            }
        }
    }
}
