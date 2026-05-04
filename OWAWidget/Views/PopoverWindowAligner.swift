import AppKit
import SwiftUI

struct PopoverWindowAligner: NSViewRepresentable {
    let popoverSize: PopoverSize

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> PopoverWindowAlignmentView {
        let view = PopoverWindowAlignmentView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: PopoverWindowAlignmentView, context: Context) {
        nsView.coordinator = context.coordinator
        nsView.requestAlignment()
    }

    final class Coordinator {
        var anchorX: CGFloat?
    }
}

final class PopoverWindowAlignmentView: NSView {
    var coordinator: PopoverWindowAligner.Coordinator?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        requestAlignment()
    }

    func requestAlignment() {
        DispatchQueue.main.async { [weak self] in
            self?.alignWindowLeft()
        }
    }

    private func alignWindowLeft() {
        guard let window, let coordinator else { return }

        if coordinator.anchorX == nil {
            coordinator.anchorX = window.frame.minX
        }

        let visibleFrame = window.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? window.frame
        let anchorX = coordinator.anchorX ?? window.frame.minX
        var frame = window.frame
        let originX = PopoverWindowPositioning.leftAlignedOriginX(
            anchorX: anchorX,
            windowWidth: frame.width,
            visibleFrame: visibleFrame
        )

        guard abs(frame.origin.x - originX) > 0.5 else { return }

        frame.origin.x = originX
        window.setFrame(frame, display: true, animate: false)
    }
}
