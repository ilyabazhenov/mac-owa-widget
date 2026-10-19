import AppKit
import UniformTypeIdentifiers

/// `RichText` in and out of the editor's attributed string.
///
/// The editor runs on TextKit 1 (its attachment cells draw pictures at the size given), and
/// there a list marker is text: each list item starts with "\t•\t" or "\t1.\t", marked with
/// `markerKey` so it is never taken for what the user typed. The paragraph style carries the
/// lists (`textLists`, outermost first) and the indent.
@MainActor
enum RichTextAttributed {
    static let markerKey = NSAttributedString.Key("OWAWidgetListMarker")
    /// How far each list level indents: room for a marker up to "99." before the text.
    static let indentStep: CGFloat = 28

    // MARK: - Attributes

    static func paragraphStyle(list: [RichText.ListKind]) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        guard !list.isEmpty else { return style }
        let depth = CGFloat(list.count)
        style.textLists = list.map { NSTextList(markerFormat: $0 == .bullet ? .disc : .decimal, options: 0) }
        // The marker ends just before the text; wrapped lines line up with the text.
        style.tabStops = [
            NSTextTab(textAlignment: .right, location: indentStep * depth - 6),
            NSTextTab(textAlignment: .left, location: indentStep * depth),
        ]
        style.headIndent = indentStep * depth
        return style
    }

    /// The lists a paragraph style puts its paragraph in. A list numbered any way (letters,
    /// Roman, hexadecimal, octal) counts as numbered.
    static func list(of style: NSParagraphStyle?) -> [RichText.ListKind] {
        guard let lists = style?.textLists, !lists.isEmpty else { return [] }
        return lists.prefix(RichText.maxListDepth).map { list in
            let format = list.markerFormat.rawValue.lowercased()
            let numbered = ["decimal", "alpha", "roman", "hexadecimal", "octal", "latin"].contains { format.contains($0) }
            return numbered ? .numbered : .bullet
        }
    }

    static func font(_ base: NSFont, style: RichText.Style) -> NSFont {
        var traits = base.fontDescriptor.symbolicTraits
        if style.contains(.bold) { traits.insert(.bold) } else { traits.remove(.bold) }
        if style.contains(.italic) { traits.insert(.italic) } else { traits.remove(.italic) }
        return NSFont(descriptor: base.fontDescriptor.withSymbolicTraits(traits), size: base.pointSize) ?? base
    }

    /// What a run of this style looks like in the editor. No color but the text's own, so
    /// either theme reads.
    static func attributes(style: RichText.Style, link: URL?, base: NSFont) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [.font: font(base, style: style), .foregroundColor: NSColor.textColor]
        if style.contains(.underline) { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if style.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if let link = RichText.allowedLink(link) { attributes[.link] = link }
        return attributes
    }

    static func style(of attributes: [NSAttributedString.Key: Any]) -> RichText.Style {
        var style: RichText.Style = []
        if let font = attributes[.font] as? NSFont {
            let traits = font.fontDescriptor.symbolicTraits
            if traits.contains(.bold) { style.insert(.bold) }
            if traits.contains(.italic) { style.insert(.italic) }
        }
        if let underline = attributes[.underlineStyle] as? Int, underline != 0 { style.insert(.underline) }
        if let strike = attributes[.strikethroughStyle] as? Int, strike != 0 { style.insert(.strikethrough) }
        return style
    }

    static func link(of attributes: [NSAttributedString.Key: Any]) -> URL? {
        switch attributes[.link] {
        case let url as URL: RichText.allowedLink(url)
        case let string as String: RichText.allowedLink(URL(string: string))
        default: nil
        }
    }

    static func marker(_ marker: String, list: [RichText.ListKind], base: NSFont) -> NSAttributedString {
        NSAttributedString(string: "\t\(marker)\t", attributes: [
            .font: base,
            .foregroundColor: NSColor.textColor,
            .paragraphStyle: paragraphStyle(list: list),
            markerKey: true,
        ])
    }

    // MARK: - RichText → editor

    static func attributedString(_ text: RichText, images: [MailInlineImage], base: NSFont) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var remaining = images.makeIterator()
        let markers = text.listMarkers
        for (index, block) in text.blocks.enumerated() {
            let paragraph = NSMutableAttributedString()
            if let marker = markers[index] {
                paragraph.append(self.marker(marker, list: block.list, base: base))
            }
            for run in block.runs {
                let attributes = self.attributes(style: run.style, link: run.link, base: base)
                for (partIndex, part) in run.text.split(separator: MailInlineImage.placeholder, omittingEmptySubsequences: false).enumerated() {
                    if partIndex > 0, let image = remaining.next() {
                        let picture = NSMutableAttributedString(attributedString: NSAttributedString(attachment: MailInlineImageAttachment(image)))
                        picture.addAttributes(attributes, range: NSRange(location: 0, length: picture.length))
                        paragraph.append(picture)
                    }
                    paragraph.append(NSAttributedString(string: String(part), attributes: attributes))
                }
            }
            if index < text.blocks.count - 1 {
                paragraph.append(NSAttributedString(string: "\n", attributes: attributes(style: [], link: nil, base: base)))
            }
            paragraph.addAttribute(.paragraphStyle, value: paragraphStyle(list: block.list), range: NSRange(location: 0, length: paragraph.length))
            result.append(paragraph)
        }
        return result
    }

    // MARK: - Editor → RichText

    /// What the editor holds: the blocks, and the pictures in the order of their U+FFFC marks.
    ///
    /// `pasted` is for rich text from elsewhere: its pictures are any image attachment (made
    /// into `MailInlineImage`s when `allowsImages`), and a list marker is also the "\t…\t"
    /// TextKit writes, unmarked. Without it only this editor's markers and pictures count.
    static func richText(from attributed: NSAttributedString, allowsImages: Bool = true, pasted: Bool = false) -> (text: RichText, images: [MailInlineImage]) {
        let string = attributed.string as NSString
        var blocks: [RichText.Block] = []
        var images: [MailInlineImage] = []
        var location = 0
        repeat {
            let paragraph = string.length == 0 ? NSRange(location: 0, length: 0) : string.paragraphRange(for: NSRange(location: location, length: 0))
            let content = contentRange(of: paragraph, in: string)
            let list = content.length > 0 || content.location < string.length
                ? self.list(of: attributed.attribute(.paragraphStyle, at: min(content.location, max(0, string.length - 1)), effectiveRange: nil) as? NSParagraphStyle)
                : []
            var runs: [RichText.Run] = []
            var body = content
            if let leading = leadingMarker(in: attributed, content: content, lenient: pasted && !list.isEmpty) {
                body = NSRange(location: leading.upperBound, length: content.upperBound - leading.upperBound)
            }
            if body.length > 0 {
                attributed.enumerateAttributes(in: body) { attributes, range, _ in
                    if attributes[markerKey] != nil { return }
                    if let attachment = attributes[.attachment] as? NSTextAttachment {
                        guard let image = inlineImage(attachment, allowsImages: allowsImages, pasted: pasted) else { return }
                        images.append(image)
                        runs.append(RichText.Run(text: String(MailInlineImage.placeholder), style: style(of: attributes), link: link(of: attributes)))
                        return
                    }
                    let text = string.substring(with: range)
                        .replacingOccurrences(of: String(MailInlineImage.placeholder), with: "")
                        .replacingOccurrences(of: "\u{2029}", with: "")
                    runs.append(RichText.Run(text: text, style: style(of: attributes), link: link(of: attributes)))
                }
            }
            blocks.append(RichText.Block(runs: runs, list: list))
            location = paragraph.upperBound
        } while location < string.length
        // Text ending in a line break has an empty paragraph after it.
        if string.length > 0, isTerminator(string.character(at: string.length - 1)) {
            blocks.append(RichText.Block(runs: []))
        }
        return (RichText(blocks: blocks), images)
    }

    /// The paragraph without its line break.
    static func contentRange(of paragraph: NSRange, in string: NSString) -> NSRange {
        var content = paragraph
        if content.length > 0, isTerminator(string.character(at: content.upperBound - 1)) {
            content.length -= 1
            // "\r\n" is one break.
            if content.length > 0, string.character(at: content.upperBound - 1) == 0x0D, string.character(at: content.upperBound) == 0x0A {
                content.length -= 1
            }
        }
        return content
    }

    static func isTerminator(_ character: unichar) -> Bool {
        character == 0x0A || character == 0x0D || character == 0x2029
    }

    /// The marker a list item starts with: this editor's (marked with `markerKey`), or when
    /// `lenient` the "\t…\t" TextKit itself writes.
    static func leadingMarker(in attributed: NSAttributedString, content: NSRange, lenient: Bool) -> NSRange? {
        guard content.length > 0 else { return nil }
        var effective = NSRange()
        if attributed.attribute(markerKey, at: content.location, longestEffectiveRange: &effective, in: content) != nil {
            return effective
        }
        guard lenient else { return nil }
        let text = (attributed.string as NSString).substring(with: content)
        guard let match = text.range(of: #"^\t[^\t]{1,8}\t"#, options: .regularExpression) else { return nil }
        return NSRange(location: content.location, length: NSRange(match, in: text).length)
    }

    private static func inlineImage(_ attachment: NSTextAttachment, allowsImages: Bool, pasted: Bool) -> MailInlineImage? {
        guard allowsImages else { return nil }
        if let ours = attachment as? MailInlineImageAttachment { return ours.inlineImage }
        guard pasted, let wrapper = attachment.fileWrapper, let data = wrapper.regularFileContents else { return nil }
        let name = wrapper.preferredFilename ?? wrapper.filename ?? "image.png"
        let ext = (name as NSString).pathExtension
        guard let type = UTType(filenameExtension: ext) ?? (NSBitmapImageRep(data: data) != nil ? .png : nil),
              type.conforms(to: .image) else { return nil }
        return MailPastedImages.image(data: data, type: type, baseName: (name as NSString).deletingPathExtension)
    }
}
