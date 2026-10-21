import AppKit
import SwiftUI

/// Connects a `RichTextEditor` with its `RichTextToolbar`: the toolbar shows what the
/// selection looks like and sends its buttons to the text view.
@MainActor
final class RichTextEditorController: ObservableObject {
    @Published private(set) var state = RichTextFormatState()
    /// ⌘K or the toolbar button: the toolbar asks for the address.
    @Published var isEditingLink = false
    fileprivate(set) weak var textView: RichTextView?
    /// The selection the link goes on, kept while the address is typed elsewhere.
    private(set) var linkRange = NSRange(location: 0, length: 0)

    fileprivate func attach(_ textView: RichTextView) {
        self.textView = textView
        // Reported from inside SwiftUI's updates too (a new text loaded): published after them.
        textView.onStateChange = { [weak self] state in
            DispatchQueue.main.async {
                guard let self, self.state != state else { return }
                self.state = state
            }
        }
        textView.onLinkRequest = { [weak self] in self?.beginLink() }
    }

    func toggle(_ style: RichText.Style) { perform { $0.toggle(style) } }
    func toggleList(_ kind: RichText.ListKind) { perform { $0.toggleList(kind) } }
    func indent(by delta: Int) { perform { $0.indentList(by: delta) } }

    func beginLink() {
        guard let textView, textView.isEditable else { return }
        linkRange = textView.selectedRange()
        isEditingLink = true
    }

    /// What the address field starts with: the link already there, or an address on the
    /// clipboard.
    var suggestedLink: String {
        if let link = state.link { return link.absoluteString }
        let clipboard = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Self.linkURL(from: clipboard) != nil && !clipboard.contains(where: \.isWhitespace) ? clipboard : ""
    }

    func finishLink(_ address: String?) {
        isEditingLink = false
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
        textView.setSelectedRange(linkRange)
        textView.setLink(address.flatMap(Self.linkURL), in: linkRange)
    }

    /// What was typed for a link as an address: `example.com` is a web page, `name@host` an
    /// email address. `nil` for what cannot be one.
    static func linkURL(from typed: String) -> URL? {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: \.isWhitespace) else { return nil }
        if let url = URL(string: text), url.scheme != nil { return RichText.allowedLink(url) }
        if text.contains("@"), !text.contains("/") { return URL(string: "mailto:" + text) }
        guard text.contains(".") else { return nil }
        return RichText.allowedLink(URL(string: "https://" + text))
    }

    private func perform(_ action: (RichTextView) -> Void) {
        guard let textView, textView.isEditable else { return }
        textView.window?.makeFirstResponder(textView)
        action(textView)
    }
}

/// Formatted text with pictures: what a mail or a meeting body is typed in.
///
/// `text` holds U+FFFC where each of `images` sits, in order. Pasted text keeps bold, italics,
/// underlining, strikethrough, links and lists; its fonts, sizes and colors are dropped.
struct RichTextEditor: NSViewRepresentable {
    @Binding var text: RichText
    @Binding var images: [MailInlineImage]
    var allowsImages = true
    let controller: RichTextEditorController
    /// The editor took focus (a click into it).
    var onFocus: () -> Void = {}

    static let font = NSFont.systemFont(ofSize: 13)

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        // TextKit 1: its attachment cells draw a picture at the size given.
        let textView = RichTextView(usingTextLayoutManager: false)
        textView.delegate = context.coordinator
        textView.onFocus = { [weak coordinator = context.coordinator] in coordinator?.parent.onFocus() }
        textView.allowsImages = allowsImages
        textView.baseFont = Self.font
        textView.isRichText = true
        textView.importsGraphics = allowsImages
        textView.allowsImageEditing = false
        textView.usesFontPanel = false
        textView.usesRuler = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.textContainerInset = .zero
        textView.typingAttributes = textView.baseAttributes
        textView.linkTextAttributes = [.foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.documentView = textView
        context.coordinator.load(text: text, images: images, into: textView)
        controller.attach(textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? RichTextView else { return }
        textView.isEditable = context.environment.isEnabled
        textView.isSelectable = context.environment.isEnabled
        if controller.textView !== textView { controller.attach(textView) }
        if text != context.coordinator.lastText || images != context.coordinator.lastImages {
            context.coordinator.load(text: text, images: images, into: textView)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichTextEditor
        private(set) var lastText: RichText?
        private(set) var lastImages: [MailInlineImage] = []
        /// The editor's own: a text put in from outside (a draft from the assistant, a form
        /// cleared after sending) drops its history, and the window's other fields keep theirs.
        private let undoManager = UndoManager()

        init(_ parent: RichTextEditor) { self.parent = parent }

        func undoManager(for view: NSTextView) -> UndoManager? { undoManager }

        func load(text: RichText, images: [MailInlineImage], into textView: RichTextView) {
            // Steps recorded against the old text would replay on the new one.
            undoManager.removeAllActions()
            textView.textStorage?.setAttributedString(RichTextAttributed.attributedString(text, images: images, base: textView.baseFont))
            textView.typingAttributes = textView.baseAttributes
            lastText = text
            lastImages = images
            textView.reportState()
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? RichTextView, let storage = textView.textStorage else { return }
            let content = RichTextAttributed.richText(from: storage, allowsImages: textView.allowsImages)
            textView.reportState()
            guard content.text != lastText || content.images != lastImages else { return }
            lastText = content.text
            lastImages = content.images
            parent.text = content.text
            parent.images = content.images
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            (notification.object as? RichTextView)?.reportState()
        }

        func textViewDidChangeTypingAttributes(_ notification: Notification) {
            (notification.object as? RichTextView)?.reportState()
        }
    }
}
