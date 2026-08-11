import SwiftUI
import AppKit

/// Read-only `NSTextView` for SwiftUI: system text selection across the whole body, native
/// Copy / Select All, and link clicks routed back to the app.
///
/// It deliberately has no `NSScrollView` around it — the panel already scrolls, so the view
/// reports its full laid-out height through `sizeThatFits` and grows inside the outer `ScrollView`.
///
/// The caller must hand in a string that is built once and kept (see `MeetingDetailContentView`):
/// a body containing a table can never compare equal across rebuilds, because `NSTextTable` and
/// `NSTextTableBlock` use identity equality, and re-setting the text storage wipes the user's
/// selection mid-drag.
struct SelectableAttributedText: NSViewRepresentable {
    let attributed: NSAttributedString
    let onOpenURL: (URL) -> Void

    func makeNSView(context: Context) -> NSTextView {
        let textView = Self.makeTextView()
        textView.delegate = context.coordinator
        return textView
    }

    /// Separate from `makeNSView` so the configuration can be asserted in tests — one flag here
    /// decides whether the body lands where SwiftUI put it.
    static func makeTextView() -> NSTextView {
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        // Must stay off: a self-resizing text view whose text is taller than the frame it was given
        // grows itself and shifts its origin (frame (0, 0, 300, 400) becomes (0, -499, 300, 899)),
        // which in the panel showed up as the agenda sliding down behind a blank gap. The height
        // comes from `sizeThatFits`; the view itself must not have an opinion.
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        // The attributed string already carries the link colour; without clearing these the text
        // view would repaint links in its own blue and add a second underline.
        textView.linkTextAttributes = [:]
        return textView
    }

    func updateNSView(_ textView: NSTextView, context: Context) {
        context.coordinator.onOpenURL = onOpenURL
        guard context.coordinator.applied !== attributed else { return }
        context.coordinator.applied = attributed
        textView.textStorage?.setAttributedString(attributed)
    }

    /// Measured on a throwaway layout stack rather than on the live text container: the container
    /// tracks the text view's real width, and overwriting its size here would lay the text out
    /// against a width SwiftUI has not applied yet.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView textView: NSTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0, width < .greatestFiniteMagnitude else { return nil }
        return CGSize(width: width, height: context.coordinator.height(of: attributed, width: width))
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var onOpenURL: (URL) -> Void = { _ in }
        /// Last string handed to the text view — identity is the right check, since the view model
        /// builds it once per body.
        var applied: NSAttributedString?

        private let storage = NSTextStorage()
        private let layoutManager = NSLayoutManager()
        private let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        /// Held strongly on purpose: an `ObjectIdentifier` key could match a new string allocated
        /// at the address of a released one and hand back a stale height.
        private var measured: NSAttributedString?
        private var measuredWidth: CGFloat = 0
        private var cachedHeight: CGFloat = 0

        override init() {
            super.init()
            container.lineFragmentPadding = 0
            layoutManager.addTextContainer(container)
            storage.addLayoutManager(layoutManager)
        }

        /// SwiftUI asks for a size several times per layout pass; laying a long agenda out each
        /// time is wasted work, so the last answer is memoized.
        func height(of attributed: NSAttributedString, width: CGFloat) -> CGFloat {
            if measured === attributed, measuredWidth == width { return cachedHeight }

            storage.setAttributedString(attributed)
            container.size = NSSize(width: width, height: .greatestFiniteMagnitude)
            layoutManager.ensureLayout(for: container)

            cachedHeight = ceil(layoutManager.usedRect(for: container).height)
            measured = attributed
            measuredWidth = width
            return cachedHeight
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
            guard let url else { return false }
            onOpenURL(url)
            return true
        }
    }
}
