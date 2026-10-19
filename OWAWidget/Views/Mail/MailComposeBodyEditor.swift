import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The compose window's text: plain text, plus pictures pasted or dropped into it.
///
/// `text` holds U+FFFC where each of `images` sits, in order — the editor's own text, without
/// fonts or colors: what is pasted comes in as plain text, a picture as a picture.
struct MailComposeBodyEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var images: [MailInlineImage]
    /// The editor took focus (a click into it).
    var onFocus: () -> Void = {}

    static let font = NSFont.systemFont(ofSize: 13)
    /// Wider pictures are shown smaller, and no wider than the text; they are sent as they are.
    static let maxImageWidth: CGFloat = 360

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        // TextKit 1: its attachment cells draw a picture at the size given.
        let textView = MailComposeTextView(usingTextLayoutManager: false)
        textView.delegate = context.coordinator
        textView.onFocus = { [weak coordinator = context.coordinator] in coordinator?.parent.onFocus() }
        textView.isRichText = true
        textView.importsGraphics = true
        textView.allowsImageEditing = false
        textView.usesFontPanel = false
        textView.usesRuler = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.textContainerInset = .zero
        textView.typingAttributes = Self.typingAttributes
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
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? MailComposeTextView else { return }
        textView.isEditable = context.environment.isEnabled
        textView.isSelectable = context.environment.isEnabled
        if text != context.coordinator.lastText || images != context.coordinator.lastImages {
            context.coordinator.load(text: text, images: images, into: textView)
        }
    }

    static var typingAttributes: [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: NSColor.textColor]
    }

    /// The text and pictures as an attributed string; a U+FFFC with no picture left is dropped.
    static func attributedString(text: String, images: [MailInlineImage]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var remaining = images.makeIterator()
        for (index, part) in text.split(separator: MailInlineImage.placeholder, omittingEmptySubsequences: false).enumerated() {
            if index > 0, let image = remaining.next() {
                result.append(NSAttributedString(attachment: MailInlineImageAttachment(image)))
            }
            result.append(NSAttributedString(string: String(part)))
        }
        result.addAttributes(typingAttributes, range: NSRange(location: 0, length: result.length))
        return result
    }

    /// What the editor holds, back as text with U+FFFC and the pictures in order. Anything else
    /// that ended up as an attachment is not sent.
    static func content(of storage: NSAttributedString) -> (text: String, images: [MailInlineImage]) {
        var text = ""
        var images: [MailInlineImage] = []
        let string = storage.string as NSString
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if let attachment = value as? MailInlineImageAttachment {
                text.append(MailInlineImage.placeholder)
                images.append(attachment.inlineImage)
            } else {
                text += string.substring(with: range).replacingOccurrences(of: String(MailInlineImage.placeholder), with: "")
            }
        }
        return (text, images)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MailComposeBodyEditor
        private(set) var lastText: String?
        private(set) var lastImages: [MailInlineImage] = []

        init(_ parent: MailComposeBodyEditor) { self.parent = parent }

        func load(text: String, images: [MailInlineImage], into textView: NSTextView) {
            textView.textStorage?.setAttributedString(MailComposeBodyEditor.attributedString(text: text, images: images))
            lastText = text
            lastImages = images
        }

        func textDidChange(_ notification: Notification) {
            guard let storage = (notification.object as? NSTextView)?.textStorage else { return }
            let content = MailComposeBodyEditor.content(of: storage)
            lastText = content.text
            lastImages = content.images
            parent.text = content.text
            parent.images = content.images
        }
    }
}

/// A pasted picture in the editor: carries the bytes that will be sent.
final class MailInlineImageAttachment: NSTextAttachment {
    let inlineImage: MailInlineImage

    @MainActor
    init(_ inlineImage: MailInlineImage) {
        self.inlineImage = inlineImage
        super.init(data: nil, ofType: nil)
        // Copied within the editor, the picture travels as RTFD with these bytes.
        let wrapper = FileWrapper(regularFileWithContents: inlineImage.data)
        wrapper.preferredFilename = inlineImage.name
        fileWrapper = wrapper
        guard let picture = NSImage(data: inlineImage.data) else { return }
        attachmentCell = MailInlineImageCell(imageCell: picture)
    }

    required init?(coder: NSCoder) { nil }
}

/// A pasted picture as the editor draws it: rounded, with a hairline so a dark screenshot does
/// not melt into a dark window, outlined in the accent color while selected. No wider than the
/// line it sits on, so a narrow window shrinks it.
final class MailInlineImageCell: NSTextAttachmentCell {
    private static let cornerRadius: CGFloat = 6

    private func size(fitting width: CGFloat) -> NSSize {
        guard let natural = image?.size, natural.width > 0 else { return NSSize(width: 1, height: 1) }
        let fitted = min(natural.width, MailComposeBodyEditor.maxImageWidth, max(40, width))
        return NSSize(width: fitted, height: (natural.height * fitted / natural.width).rounded())
    }

    // Layout runs on the main thread, as the editor does.
    override func cellSize() -> NSSize {
        MainActor.assumeIsolated { size(fitting: MailComposeBodyEditor.maxImageWidth) }
    }

    override func cellFrame(
        for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect,
        glyphPosition position: NSPoint, characterIndex charIndex: Int
    ) -> NSRect {
        let width = lineFrag.width - 2 * textContainer.lineFragmentPadding - 2
        return MainActor.assumeIsolated { NSRect(origin: .zero, size: size(fitting: width)) }
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?, characterIndex charIndex: Int, layoutManager: NSLayoutManager) {
        let selected = (controlView as? NSTextView)?.selectedRanges.contains {
            let range = $0.rangeValue
            return range.length > 0 && NSLocationInRange(charIndex, range)
        } ?? false
        let frame = cellFrame.insetBy(dx: 0.5, dy: 0.5)
        let outline = NSBezierPath(roundedRect: frame, xRadius: Self.cornerRadius, yRadius: Self.cornerRadius)
        NSGraphicsContext.saveGraphicsState()
        outline.addClip()
        image?.draw(in: cellFrame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        if selected {
            NSColor.controlAccentColor.withAlphaComponent(0.25).setFill()
            outline.fill()
            NSColor.controlAccentColor.setStroke()
            outline.lineWidth = 2
        } else {
            NSColor.separatorColor.setStroke()
            outline.lineWidth = 1
        }
        outline.stroke()
    }
}

/// Pastes and drops come in as plain text, or as pictures when the pasteboard holds them.
final class MailComposeTextView: NSTextView {
    var onFocus: () -> Void = {}

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocus() }
        return became
    }

    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        if let content = MailPastedImages.content(from: pboard) {
            insert(content)
            return true
        }
        if let string = pboard.string(forType: .string) {
            insertText(string, replacementRange: selectedRange())
            return true
        }
        return false
    }

    private func insert(_ content: NSAttributedString) {
        let range = selectedRange()
        let inserted = NSMutableAttributedString(attributedString: content)
        inserted.addAttributes(MailComposeBodyEditor.typingAttributes, range: NSRange(location: 0, length: inserted.length))
        guard let storage = textStorage, shouldChangeText(in: range, replacementString: inserted.string) else { return }
        storage.replaceCharacters(in: range, with: inserted)
        didChangeText()
        setSelectedRange(NSRange(location: range.location + inserted.length, length: 0))
        typingAttributes = MailComposeBodyEditor.typingAttributes
    }
}

/// Pictures on a pasteboard, as they will be sent.
@MainActor
enum MailPastedImages {
    /// What to insert when the pasteboard holds pictures: the pictures, or text with pictures in
    /// it (copied from this editor or a web page) with the text plain. `nil` for anything else.
    static func content(from pboard: NSPasteboard) -> NSAttributedString? {
        // Files first: a file copied in Finder also carries its icon as a picture.
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let urls = pboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL], !urls.isEmpty {
            let images = urls.compactMap { url -> MailInlineImage? in
                guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image),
                      let data = try? Data(contentsOf: url) else { return nil }
                return image(data: data, type: type, baseName: url.deletingPathExtension().lastPathComponent)
            }
            return images.isEmpty ? nil : attachments(images)
        }
        if let rtfd = pboard.data(forType: .rtfd),
           let attributed = NSAttributedString(rtfd: rtfd, documentAttributes: nil),
           let content = plainWithPictures(attributed) {
            return content
        }
        // Text copied from Office also carries a picture of itself: it is text that was meant.
        if let string = pboard.string(forType: .string), !string.isEmpty { return nil }
        for type in [UTType.png, .jpeg, .gif, .tiff, .heic] {
            if let data = pboard.data(forType: NSPasteboard.PasteboardType(type.identifier)),
               let image = image(data: data, type: type, baseName: "image") {
                return attachments([image])
            }
        }
        return nil
    }

    private static func attachments(_ images: [MailInlineImage]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for image in images { result.append(NSAttributedString(attachment: MailInlineImageAttachment(image))) }
        return result
    }

    /// Rich text with its fonts and colors dropped and its pictures kept; `nil` when it has no
    /// pictures (then it is pasted as plain text).
    static func plainWithPictures(_ attributed: NSAttributedString) -> NSAttributedString? {
        let result = NSMutableAttributedString()
        var hasPictures = false
        let string = attributed.string as NSString
        attributed.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
            if let attachment = value as? NSTextAttachment {
                guard let wrapper = attachment.fileWrapper, let data = wrapper.regularFileContents else { return }
                let name = wrapper.preferredFilename ?? wrapper.filename ?? "image.png"
                let ext = (name as NSString).pathExtension
                guard let type = UTType(filenameExtension: ext) ?? (NSBitmapImageRep(data: data) != nil ? .png : nil),
                      type.conforms(to: .image),
                      let image = image(data: data, type: type, baseName: (name as NSString).deletingPathExtension) else { return }
                hasPictures = true
                result.append(NSAttributedString(attachment: MailInlineImageAttachment(image)))
            } else {
                let text = string.substring(with: range).replacingOccurrences(of: String(MailInlineImage.placeholder), with: "")
                result.append(NSAttributedString(string: text))
            }
        }
        return hasPictures ? result : nil
    }

    /// PNG, JPEG and GIF go as they are; anything else (TIFF from a copy, HEIC from Photos) as
    /// PNG, which every mail client shows. A large opaque picture goes as JPEG when that is
    /// smaller: a Retina screenshot shrinks several times.
    static func image(data: Data, type: UTType, baseName: String) -> MailInlineImage? {
        if type.conforms(to: .gif) {
            return MailInlineImage(name: baseName + ".gif", contentType: "image/gif", data: data)
        }
        guard let rep = NSBitmapImageRep(data: data) else { return nil }
        var best: (data: Data, ext: String, mime: String)
        if type.conforms(to: .png) {
            best = (data, "png", "image/png")
        } else if type.conforms(to: .jpeg) {
            best = (data, "jpg", "image/jpeg")
        } else {
            guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
            best = (png, "png", "image/png")
        }
        if best.mime == "image/png", best.data.count > 1_000_000, !rep.hasAlpha,
           let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]),
           jpeg.count < best.data.count {
            best = (jpeg, "jpg", "image/jpeg")
        }
        return MailInlineImage(name: baseName + "." + best.ext, contentType: best.mime, data: best.data)
    }
}
