import Foundation

/// The HTML a mail or meeting body goes to Exchange as. Only a handful of tags, no classes and
/// no colors, so Outlook and OWA show it alike and a dark theme does not paint black on black.
/// Everything the user typed is escaped: nothing in the text is taken as markup.
enum RichTextHTML {
    /// The blocks as HTML: a `<div>` per paragraph, `<ul>`/`<ol>` for lists with a deeper list
    /// inside its parent's `<li>`. Each U+FFFC becomes the next of `inlineImages` by its `cid:`;
    /// one with no picture left is dropped.
    static func fragment(_ text: RichText, inlineImages: [MailInlineImage] = []) -> String {
        var images = inlineImages.makeIterator()
        var html = ""
        /// The lists open now, outermost first, and whether each has an `<li>` open.
        var open: [(kind: RichText.ListKind, itemOpen: Bool)] = []

        func close(downTo depth: Int) {
            while open.count > depth {
                let list = open.removeLast()
                if list.itemOpen { html += "</li>" }
                html += list.kind == .bullet ? "</ul>" : "</ol>"
            }
        }

        for block in text.blocks {
            let content = inline(block.runs, images: &images)
            guard block.isListItem else {
                close(downTo: 0)
                html += "<div>\(content.isEmpty ? "<br>" : content)</div>"
                continue
            }
            let common = zip(open.map(\.kind), block.list).prefix { $0 == $1 }.count
            close(downTo: common)
            if open.count == block.list.count, open[open.count - 1].itemOpen {
                html += "</li>"
                open[open.count - 1].itemOpen = false
            }
            while open.count < block.list.count {
                // An item that starts deeper than the one before it hangs in an unmarked parent.
                if let last = open.indices.last, !open[last].itemOpen {
                    html += "<li style=\"list-style: none;\">"
                    open[last].itemOpen = true
                }
                let kind = block.list[open.count]
                html += kind == .bullet ? "<ul style=\"margin-top: 0; margin-bottom: 0;\">" : "<ol style=\"margin-top: 0; margin-bottom: 0;\">"
                open.append((kind, false))
            }
            html += "<li>\(content.isEmpty ? "<br>" : content)"
            open[open.count - 1].itemOpen = true
        }
        close(downTo: 0)
        return html
    }

    /// The runs of one block: each style as its tag, links as `<a>`, pictures as `<img>`, line
    /// breaks inside a paragraph (U+2028) as `<br>`.
    private static func inline(_ runs: [RichText.Run], images: inout IndexingIterator<[MailInlineImage]>) -> String {
        var html = ""
        for run in runs {
            var text = ""
            // Escaped a stretch at a time, between pictures and line breaks.
            var stretch = ""
            for character in run.text {
                guard character == MailInlineImage.placeholder || character == "\u{2028}" else {
                    stretch.append(character)
                    continue
                }
                text += escape(stretch)
                stretch = ""
                if character == "\u{2028}" {
                    text += "<br>"
                } else if let image = images.next() {
                    text += "<img src=\"cid:\(escape(image.contentID))\" alt=\"\(escape(image.name))\" style=\"max-width: 100%;\">"
                }
            }
            text += escape(stretch)
            guard !text.isEmpty else { continue }
            if run.style.contains(.strikethrough) { text = "<s>\(text)</s>" }
            if run.style.contains(.underline) { text = "<u>\(text)</u>" }
            if run.style.contains(.italic) { text = "<i>\(text)</i>" }
            if run.style.contains(.bold) { text = "<b>\(text)</b>" }
            if let link = RichText.allowedLink(run.link) {
                text = "<a href=\"\(escape(link.absoluteString))\">\(text)</a>"
            }
            html += text
        }
        return html
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
