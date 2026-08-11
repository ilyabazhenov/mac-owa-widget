import SwiftUI
import AppKit

/// Read-only `NSTextView` for SwiftUI: system text selection across the whole body, native
/// Copy / Select All, and link clicks routed back to the app.
///
/// It deliberately has no `NSScrollView` around it — the panel already scrolls, so the view
/// reports its full laid-out height through `sizeThatFits` and grows inside the outer `ScrollView`.
struct SelectableAttributedText: NSViewRepresentable {
    let attributed: NSAttributedString
    let onOpenURL: (URL) -> Void

    func makeNSView(context: Context) -> NSTextView {
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.delegate = context.coordinator
        // The attributed string already carries the link colour; without clearing these the text
        // view would repaint links in its own blue and add a second underline.
        textView.linkTextAttributes = [:]
        return textView
    }

    func updateNSView(_ textView: NSTextView, context: Context) {
        context.coordinator.onOpenURL = onOpenURL
        guard textView.textStorage?.isEqual(to: attributed) == false else { return }
        textView.textStorage?.setAttributedString(attributed)
        textView.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView textView: NSTextView, context: Context) -> CGSize? {
        guard let container = textView.textContainer, let layoutManager = textView.layoutManager else { return nil }
        let width = proposal.width ?? container.containerSize.width
        guard width > 0, width < .greatestFiniteMagnitude else { return nil }

        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: container)
        return CGSize(width: width, height: ceil(layoutManager.usedRect(for: container).height))
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var onOpenURL: (URL) -> Void = { _ in }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
            guard let url else { return false }
            onOpenURL(url)
            return true
        }
    }
}
