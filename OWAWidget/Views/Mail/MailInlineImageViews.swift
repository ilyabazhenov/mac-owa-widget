import AppKit
import UniformTypeIdentifiers

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
    /// Wider pictures are shown smaller, and no wider than the text; they are sent as they are.
    static let maxImageWidth: CGFloat = 360

    private func size(fitting width: CGFloat) -> NSSize {
        guard let natural = image?.size, natural.width > 0 else { return NSSize(width: 1, height: 1) }
        let fitted = min(natural.width, Self.maxImageWidth, max(40, width))
        return NSSize(width: fitted, height: (natural.height * fitted / natural.width).rounded())
    }

    // Layout runs on the main thread, as the editor does.
    override func cellSize() -> NSSize {
        MainActor.assumeIsolated { size(fitting: Self.maxImageWidth) }
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

/// Pictures on a pasteboard, as they will be sent.
@MainActor
enum MailPastedImages {
    /// Picture files copied in Finder; `nil` when the pasteboard holds no files, empty when
    /// none of them is a picture. Files first: a file copied in Finder also carries its icon
    /// as a picture.
    static func files(from pboard: NSPasteboard) -> [MailInlineImage]? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = pboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL], !urls.isEmpty else { return nil }
        return urls.compactMap { url -> MailInlineImage? in
            guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image),
                  let data = try? Data(contentsOf: url) else { return nil }
            return image(data: data, type: type, baseName: url.deletingPathExtension().lastPathComponent)
        }
    }

    /// Rich text on the pasteboard: RTFD (with its pictures), RTF, or HTML read without
    /// anything that would load from the network.
    static func richText(from pboard: NSPasteboard) -> NSAttributedString? {
        if let rtfd = pboard.data(forType: .rtfd), let text = NSAttributedString(rtfd: rtfd, documentAttributes: nil) { return text }
        if let rtf = pboard.data(forType: .rtf), let text = NSAttributedString(rtf: rtf, documentAttributes: nil) { return text }
        if let html = pboard.string(forType: .html), let data = offlineHTML(html).data(using: .utf8) {
            return NSAttributedString(html: data, options: [.characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil)
        }
        return nil
    }

    /// HTML with everything that would load taken out (pictures, media, stylesheets, URL
    /// attributes but links, styles that fetch) and scripts and frames too: the formatting it
    /// keeps never needs them, and reading it must not reach the network.
    static func offlineHTML(_ html: String) -> String {
        MailHTMLScanner.process(html, sanitize: true, offline: true) { _ in nil }
    }

    /// A picture copied on its own (a screenshot, an image from a browser). Text copied from
    /// Office also carries a picture of itself: it is text that was meant.
    static func picture(from pboard: NSPasteboard) -> MailInlineImage? {
        if let string = pboard.string(forType: .string), !string.isEmpty { return nil }
        for type in [UTType.png, .jpeg, .gif, .tiff, .heic] {
            if let data = pboard.data(forType: NSPasteboard.PasteboardType(type.identifier)),
               let image = image(data: data, type: type, baseName: "image") {
                return image
            }
        }
        return nil
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
