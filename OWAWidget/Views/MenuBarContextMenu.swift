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
    let menu: NSMenu

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.menu = menu
        context.coordinator.startIfNeeded()
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator {
        var menu: NSMenu?
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
            guard let menu, let view = event.window?.contentView else { return }
            NSMenu.popUpContextMenu(menu, with: event, for: view)
        }
    }
}
