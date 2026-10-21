import AppKit

/// What the toolbar shows for the selection.
struct RichTextFormatState: Equatable {
    var style: RichText.Style = []
    /// The lists the paragraph at the selection sits in; empty for a paragraph.
    var list: [RichText.ListKind] = []
    var link: URL?
}

/// The text view behind `RichTextEditor`: styles, lists with their markers kept right, pastes
/// that keep the formatting worth sending and drop the rest.
final class RichTextView: NSTextView {
    var onFocus: () -> Void = {}
    var onStateChange: (RichTextFormatState) -> Void = { _ in }
    /// ⌘K: the editor asks for the address.
    var onLinkRequest: () -> Void = {}
    var allowsImages = true
    var baseFont = NSFont.systemFont(ofSize: 13)

    private var isNormalizing = false

    var baseAttributes: [NSAttributedString.Key: Any] {
        RichTextAttributed.attributes(style: [], link: nil, base: baseFont)
    }

    /// An edit that adds or removes a line break, or touches a marker, starts an undo step of
    /// its own: the marker fixes `normalizeLists` makes go into the same step, so ⌘Z takes
    /// both back. Without the break the text would sit in an earlier typing step and ⌘Z would
    /// take back only the marker.
    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        if !isNormalizing, let storage = textStorage, affectsLines(affectedCharRange, replacement: replacementString, in: storage) {
            breakUndoCoalescing()
        }
        return super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
    }

    private func affectsLines(_ range: NSRange, replacement: String?, in storage: NSTextStorage) -> Bool {
        if let replacement, replacement.contains(where: \.isNewline) { return true }
        guard range.length > 0, range.upperBound <= storage.length else { return false }
        if (storage.string as NSString).substring(with: range).contains(where: \.isNewline) { return true }
        var touchesMarker = false
        storage.enumerateAttribute(RichTextAttributed.markerKey, in: range) { value, _, stop in
            if value != nil { touchesMarker = true; stop.pointee = true }
        }
        return touchesMarker
    }

    /// Lists are put right before anyone hears of the change.
    override func didChangeText() {
        normalizeLists()
        super.didChangeText()
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocus() }
        return became
    }

    // MARK: - State

    var formatState: RichTextFormatState {
        guard let storage = textStorage else { return RichTextFormatState() }
        let range = selectedRange()
        var state = RichTextFormatState()
        if range.length == 0 {
            state.style = RichTextAttributed.style(of: typingAttributes)
            state.link = RichTextAttributed.link(of: typingAttributes)
        } else {
            var style: RichText.Style?
            storage.enumerateAttributes(in: range) { attributes, _, _ in
                guard attributes[RichTextAttributed.markerKey] == nil else { return }
                let runStyle = RichTextAttributed.style(of: attributes)
                style = style.map { $0.intersection(runStyle) } ?? runStyle
                if state.link == nil { state.link = RichTextAttributed.link(of: attributes) }
            }
            state.style = style ?? []
        }
        state.list = paragraphs(touching: range).first.map { list(of: $0) } ?? []
        return state
    }

    func reportState() { onStateChange(formatState) }

    // MARK: - Paragraphs

    /// A paragraph of the text: where it is, without its line break and with it.
    struct Paragraph {
        let content: NSRange
        let full: NSRange
        /// Where it starts: what `normalizeLists(setting:)` knows it by.
        var location: Int { full.location }
    }

    /// Whether the text ends in an empty paragraph after a final line break (or is empty).
    private func endsInEmptyParagraph(_ string: NSString) -> Bool {
        string.length == 0 || RichTextAttributed.isTerminator(string.character(at: string.length - 1))
    }

    /// Every paragraph, the empty one after a final line break included.
    func allParagraphs() -> [Paragraph] {
        let string = (textStorage?.string ?? "") as NSString
        var result: [Paragraph] = []
        var location = 0
        while location < string.length {
            let paragraph = string.paragraphRange(for: NSRange(location: location, length: 0))
            result.append(Paragraph(content: RichTextAttributed.contentRange(of: paragraph, in: string), full: paragraph))
            location = paragraph.upperBound
        }
        if endsInEmptyParagraph(string) {
            let end = NSRange(location: string.length, length: 0)
            result.append(Paragraph(content: end, full: end))
        }
        return result
    }

    /// The paragraphs a selection is in: from the one at its start up to the one it ends in. A
    /// selection ending right at a paragraph's start (a whole line picked) leaves it out.
    func paragraphs(touching range: NSRange) -> [Paragraph] {
        let string = (textStorage?.string ?? "") as NSString
        let length = string.length
        var location = min(range.location, length)
        if location == length {
            if endsInEmptyParagraph(string) {
                let end = NSRange(location: length, length: 0)
                return [Paragraph(content: end, full: end)]
            }
            // At the very end of the last paragraph.
            location = length - 1
        }
        var result: [Paragraph] = []
        while location < length {
            let paragraph = string.paragraphRange(for: NSRange(location: location, length: 0))
            result.append(Paragraph(content: RichTextAttributed.contentRange(of: paragraph, in: string), full: paragraph))
            location = paragraph.upperBound
            if location >= range.upperBound { break }
        }
        return result
    }

    /// The lists a paragraph is in. The empty paragraph at the very end has no characters of
    /// its own: there the typing attributes say, while the caret is in it.
    func list(of paragraph: Paragraph) -> [RichText.ListKind] {
        guard let storage = textStorage else { return [] }
        if paragraph.content.location < storage.length {
            return RichTextAttributed.list(of: storage.attribute(.paragraphStyle, at: paragraph.content.location, effectiveRange: nil) as? NSParagraphStyle)
        }
        guard selectedRange().location == storage.length else { return [] }
        return RichTextAttributed.list(of: typingAttributes[.paragraphStyle] as? NSParagraphStyle)
    }

    /// The marker that `location` falls on, if any.
    private func marker(at location: Int) -> NSRange? {
        guard let storage = textStorage, location < storage.length else { return nil }
        let string = storage.string as NSString
        let paragraph = string.paragraphRange(for: NSRange(location: location, length: 0))
        let content = RichTextAttributed.contentRange(of: paragraph, in: string)
        guard let marker = RichTextAttributed.leadingMarker(in: storage, content: content, lenient: false),
              marker.location <= location, location < marker.upperBound else { return nil }
        return marker
    }

    /// Never inside a marker: the caret goes after it, or past it to the line before when
    /// moving left.
    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting stillSelectingFlag: Bool) {
        var adjusted = ranges
        if !stillSelectingFlag, ranges.count == 1, let range = ranges.first?.rangeValue, range.length == 0,
           let marker = marker(at: range.location) {
            let previous = selectedRange()
            let movingLeft = previous.length == 0 && previous.location == marker.upperBound && range.location < previous.location
            let location = movingLeft && marker.location > 0 ? marker.location - 1 : marker.upperBound
            adjusted = [NSValue(range: NSRange(location: location, length: 0))]
        }
        super.setSelectedRanges(adjusted, affinity: affinity, stillSelecting: stillSelectingFlag)
    }

    /// A marker's attributes never carry on into what is typed after it.
    override var typingAttributes: [NSAttributedString.Key: Any] {
        get { super.typingAttributes }
        set {
            var attributes = newValue
            attributes.removeValue(forKey: RichTextAttributed.markerKey)
            super.typingAttributes = attributes
        }
    }

    private func markerRange(of paragraph: Paragraph) -> NSRange? {
        guard let storage = textStorage else { return nil }
        return RichTextAttributed.leadingMarker(in: storage, content: paragraph.content, lenient: !list(of: paragraph).isEmpty)
    }

    /// Where the user's own text in a paragraph starts: after its marker.
    private func textStart(of paragraph: Paragraph) -> Int {
        markerRange(of: paragraph)?.upperBound ?? paragraph.content.location
    }

    // MARK: - Keeping lists right

    /// Puts every list item's marker right — numbering, kind, one at the start and nowhere else
    /// — and its indent, as one change. `lists` gives paragraphs (by where they start) new
    /// lists first.
    ///
    /// Runs after each edit in the same event, so one ⌘Z takes back the edit and this together;
    /// not while undoing, which brings back text that was already right.
    func normalizeLists(setting lists: [Int: [RichText.ListKind]] = [:]) {
        guard !isNormalizing, let storage = textStorage,
              !(undoManager?.isUndoing ?? false), !(undoManager?.isRedoing ?? false) else { return }
        isNormalizing = true
        defer { isNormalizing = false }

        let paragraphs = allParagraphs()
        let chains = paragraphs.map { lists[$0.location].map { Array($0.prefix(RichText.maxListDepth)) } ?? list(of: $0) }
        let markers = RichText(blocks: chains.map { RichText.Block(runs: [], list: $0) }).listMarkers

        struct Edit {
            let range: NSRange
            let replacement: NSAttributedString
            let oldMarkerLength: Int
            let newMarkerLength: Int
            /// Marker characters left in the middle, by offset in the paragraph.
            let strays: [NSRange]
        }
        var edits: [Edit] = []
        for (index, paragraph) in paragraphs.enumerated() {
            let chain = chains[index]
            let content = paragraph.content
            let leading = RichTextAttributed.leadingMarker(in: storage, content: content, lenient: !chain.isEmpty)
            var strays: [NSRange] = []
            let afterMarker = leading?.upperBound ?? content.location
            if content.upperBound > afterMarker {
                storage.enumerateAttribute(RichTextAttributed.markerKey, in: NSRange(location: afterMarker, length: content.upperBound - afterMarker)) { value, range, _ in
                    if value != nil { strays.append(NSRange(location: range.location - content.location, length: range.length)) }
                }
            }
            let expected = markers[index].map { "\t\($0)\t" }
            let current = leading.map { (storage.string as NSString).substring(with: $0) }
            let markedLeading = leading.map { storage.attribute(RichTextAttributed.markerKey, at: $0.location, effectiveRange: nil) != nil } ?? true
            let wantedStyle = RichTextAttributed.paragraphStyle(list: chain)
            let style = content.location < storage.length
                ? storage.attribute(.paragraphStyle, at: content.location, effectiveRange: nil) as? NSParagraphStyle
                : typingAttributes[.paragraphStyle] as? NSParagraphStyle
            let styleRight = chain.isEmpty
                ? RichTextAttributed.list(of: style).isEmpty
                : RichTextAttributed.list(of: style) == chain && style?.headIndent == wantedStyle.headIndent
            let changesList = lists[paragraph.location] != nil
            guard expected != current || !strays.isEmpty || !markedLeading || !styleRight || changesList else { continue }

            let fixed = NSMutableAttributedString()
            if let marker = markers[index] {
                fixed.append(RichTextAttributed.marker(marker, list: chain, base: baseFont))
            }
            let body = NSRange(location: afterMarker, length: paragraph.full.upperBound - afterMarker)
            let text = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: body))
            for stray in strays.reversed() {
                text.deleteCharacters(in: NSRange(location: stray.location - (afterMarker - content.location), length: stray.length))
            }
            fixed.append(text)
            // The line break carries the paragraph's style too.
            fixed.addAttribute(.paragraphStyle, value: wantedStyle, range: NSRange(location: 0, length: fixed.length))
            edits.append(Edit(
                range: paragraph.full, replacement: fixed,
                oldMarkerLength: leading?.length ?? 0, newMarkerLength: fixed.length - text.length,
                strays: strays
            ))
        }
        guard !edits.isEmpty,
              shouldChangeText(inRanges: edits.map { NSValue(range: $0.range) }, replacementStrings: edits.map { $0.replacement.string })
        else { return }

        func map(_ position: Int) -> Int {
            var shift = 0
            for edit in edits {
                if position < edit.range.location { break }
                if position > edit.range.upperBound {
                    shift += edit.replacement.length - edit.range.length
                    continue
                }
                let offset = position - edit.range.location
                guard offset > edit.oldMarkerLength else { return edit.range.location + shift + edit.newMarkerLength }
                let straysBefore = edit.strays.filter { $0.location < offset }.reduce(0) { $0 + min($1.length, offset - $1.location) }
                return edit.range.location + shift + edit.newMarkerLength + offset - edit.oldMarkerLength - straysBefore
            }
            return position + shift
        }
        let selection = selectedRanges.map(\.rangeValue).map { range -> NSValue in
            let start = map(range.location)
            let end = map(range.upperBound)
            return NSValue(range: NSRange(location: start, length: max(0, end - start)))
        }
        storage.beginEditing()
        for edit in edits.reversed() {
            storage.replaceCharacters(in: edit.range, with: edit.replacement)
        }
        storage.endEditing()
        selectedRanges = selection
        // The caret may not have moved: what is typed next still takes its paragraph's lists.
        let caret = selectedRange()
        if caret.length == 0 {
            let string = storage.string as NSString
            let paragraph = string.paragraphRange(for: NSRange(location: min(caret.location, string.length), length: 0))
            if paragraph.location < storage.length {
                var attributes = typingAttributes
                attributes[.paragraphStyle] = storage.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil)
                typingAttributes = attributes
            }
        }
        didChangeText()
    }

    // MARK: - Commands

    func toggle(_ style: RichText.Style) {
        let range = selectedRange()
        let on = !formatState.style.contains(style)
        guard range.length > 0, let storage = textStorage else {
            var attributes = typingAttributes
            apply(style, on: on, to: &attributes)
            typingAttributes = attributes
            reportState()
            return
        }
        guard shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        storage.enumerateAttributes(in: range) { attributes, subrange, _ in
            guard attributes[RichTextAttributed.markerKey] == nil else { return }
            var changed = attributes
            apply(style, on: on, to: &changed)
            storage.setAttributes(changed, range: subrange)
        }
        storage.endEditing()
        didChangeText()
        reportState()
    }

    private func apply(_ style: RichText.Style, on: Bool, to attributes: inout [NSAttributedString.Key: Any]) {
        var current = RichTextAttributed.style(of: attributes)
        if on { current.formUnion(style) } else { current.subtract(style) }
        let font = attributes[.font] as? NSFont ?? baseFont
        let base = NSFont(descriptor: font.fontDescriptor, size: font.pointSize) ?? baseFont
        attributes[.font] = RichTextAttributed.font(base, style: current)
        attributes[.underlineStyle] = current.contains(.underline) ? NSUnderlineStyle.single.rawValue : nil
        attributes[.strikethroughStyle] = current.contains(.strikethrough) ? NSUnderlineStyle.single.rawValue : nil
    }

    /// The paragraphs at the selection become items of a `kind` list, or stop being list items
    /// when they all already are.
    func toggleList(_ kind: RichText.ListKind) {
        let selected = paragraphs(touching: selectedRange())
        let allAlready = selected.allSatisfy { list(of: $0).last == kind }
        var lists: [Int: [RichText.ListKind]] = [:]
        for paragraph in selected {
            let current = list(of: paragraph)
            lists[paragraph.location] = allAlready ? [] : (current.isEmpty ? [kind] : current.dropLast() + [kind])
        }
        normalizeLists(setting: lists)
        reportState()
    }

    /// One level deeper or shallower for the list items at the selection; out of the last
    /// level an item becomes a paragraph. `false` when no list item is selected.
    @discardableResult
    func indentList(by delta: Int) -> Bool {
        let selected = paragraphs(touching: selectedRange()).filter { !list(of: $0).isEmpty }
        guard !selected.isEmpty else { return false }
        var lists: [Int: [RichText.ListKind]] = [:]
        for paragraph in selected {
            var current = list(of: paragraph)
            if delta > 0 {
                guard current.count < RichText.maxListDepth, let last = current.last else { continue }
                current.append(last)
            } else {
                current.removeLast()
            }
            lists[paragraph.location] = current
        }
        if !lists.isEmpty { normalizeLists(setting: lists) }
        reportState()
        return true
    }

    /// Puts `url` on the selection, or types it as a link where there is none; `nil` takes
    /// the link off the selection.
    func setLink(_ url: URL?, in range: NSRange) {
        guard let storage = textStorage, range.upperBound <= storage.length else { return }
        let url = RichText.allowedLink(url)
        if range.length == 0 {
            guard let url else { return }
            var attributes = typingAttributes
            attributes[.link] = url
            attributes.removeValue(forKey: RichTextAttributed.markerKey)
            let inserted = NSAttributedString(string: url.absoluteString.replacingOccurrences(of: "mailto:", with: ""), attributes: attributes)
            guard shouldChangeText(in: range, replacementString: inserted.string) else { return }
            storage.replaceCharacters(in: range, with: inserted)
            didChangeText()
            setSelectedRange(NSRange(location: range.location + inserted.length, length: 0))
            attributes.removeValue(forKey: .link)
            typingAttributes = attributes
        } else {
            guard shouldChangeText(in: range, replacementString: nil) else { return }
            storage.beginEditing()
            if let url {
                storage.addAttribute(.link, value: url, range: range)
            } else {
                storage.removeAttribute(.link, range: range)
            }
            storage.endEditing()
            didChangeText()
        }
        reportState()
    }

    // MARK: - Keys

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, isEditable else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        // By key position, so the shortcuts work on a Russian layout too.
        switch (flags, event.keyCode) {
        case ([.command], 11): toggle(.bold)
        case ([.command], 34): toggle(.italic)
        case ([.command], 32): toggle(.underline)
        case ([.command, .shift], 7): toggle(.strikethrough)
        case ([.command], 40): onLinkRequest()
        case ([.command, .shift], 26): toggleList(.numbered)
        case ([.command, .shift], 28): toggleList(.bullet)
        case ([.command], 30): indentList(by: 1)
        case ([.command], 33): indentList(by: -1)
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }

    override func insertNewline(_ sender: Any?) {
        let range = selectedRange()
        let paragraph = paragraphs(touching: range).first
        let current = paragraph.map { list(of: $0) } ?? []
        if range.length == 0, let paragraph, !current.isEmpty, textStart(of: paragraph) == paragraph.content.upperBound {
            // Return in an empty item: out one level, out of the list after the last.
            normalizeLists(setting: [paragraph.location: Array(current.dropLast())])
            reportState()
            return
        }
        // Not `super`: TextKit would write a marker of its own into a list item.
        insertText("\n", replacementRange: range)
        // The new line is the next item of the same list, whatever the typing attributes say.
        if !current.isEmpty, let next = paragraphs(touching: selectedRange()).first {
            normalizeLists(setting: [next.location: current])
            reportState()
        }
    }

    override func insertTab(_ sender: Any?) {
        if indentList(by: 1) { return }
        super.insertTab(sender)
    }

    override func insertBacktab(_ sender: Any?) {
        if indentList(by: -1) { return }
        super.insertBacktab(sender)
    }

    override func deleteBackward(_ sender: Any?) {
        let range = selectedRange()
        if range.length == 0, let paragraph = paragraphs(touching: range).first {
            let current = list(of: paragraph)
            if !current.isEmpty, range.location == textStart(of: paragraph) {
                // Backspace right after the marker takes the item out one level.
                normalizeLists(setting: [paragraph.location: Array(current.dropLast())])
                reportState()
                return
            }
        }
        super.deleteBackward(sender)
    }

    /// "- ", "* " or "1. " typed at the start of a paragraph makes it a list item.
    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)
        guard (string as? String ?? (string as? NSAttributedString)?.string) == " ",
              let storage = textStorage, selectedRange().length == 0,
              let paragraph = paragraphs(touching: selectedRange()).first, list(of: paragraph).isEmpty else { return }
        let typed = NSRange(location: paragraph.content.location, length: selectedRange().location - paragraph.content.location)
        let prefix = (storage.string as NSString).substring(with: typed)
        let kind: RichText.ListKind
        switch prefix {
        case "- ", "* ", "• ": kind = .bullet
        case "1. ", "1) ": kind = .numbered
        default: return
        }
        guard shouldChangeText(in: typed, replacementString: "") else { return }
        storage.replaceCharacters(in: typed, with: "")
        didChangeText()
        normalizeLists(setting: [paragraph.location: [kind]])
        reportState()
    }

    // MARK: - Pasting

    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        if let content = pastedContent(from: pboard) {
            insertPasted(content)
            return true
        }
        if let string = pboard.string(forType: .string) {
            insertText(string, replacementRange: selectedRange())
            return true
        }
        return false
    }

    /// Pictures, or rich text with its formatting reduced to what is sent; `nil` for plain text.
    private func pastedContent(from pboard: NSPasteboard) -> NSAttributedString? {
        if allowsImages, let images = MailPastedImages.files(from: pboard) {
            return images.isEmpty ? nil : pictures(images)
        }
        if let rich = MailPastedImages.richText(from: pboard) {
            let (text, images) = RichTextAttributed.richText(from: rich, allowsImages: allowsImages, pasted: true)
            if !text.text.isEmpty || text.blocks.contains(where: \.isListItem) {
                return RichTextAttributed.attributedString(text, images: images, base: baseFont)
            }
        }
        if allowsImages, let image = MailPastedImages.picture(from: pboard) {
            return pictures([image])
        }
        return nil
    }

    private func pictures(_ images: [MailInlineImage]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for image in images { result.append(NSAttributedString(attachment: MailInlineImageAttachment(image))) }
        result.addAttributes(baseAttributes, range: NSRange(location: 0, length: result.length))
        return result
    }

    private func insertPasted(_ content: NSAttributedString) {
        let range = selectedRange()
        let inserted = NSMutableAttributedString(attributedString: content)
        if let paragraph = paragraphs(touching: range).first, inserted.length > 0 {
            let target = list(of: paragraph)
            let targetHasText = textStart(of: paragraph) < paragraph.content.upperBound
            // Into a list item or next to text, the first pasted line joins the paragraph it
            // lands in and takes its style; into an empty paragraph it keeps its own.
            if targetHasText || !target.isEmpty {
                func firstLine() -> NSRange {
                    let lineBreak = (inserted.string as NSString).rangeOfCharacter(from: .newlines)
                    return NSRange(location: 0, length: lineBreak.location == NSNotFound ? inserted.length : lineBreak.location)
                }
                if let marker = RichTextAttributed.leadingMarker(in: inserted, content: firstLine(), lenient: false) {
                    inserted.deleteCharacters(in: marker)
                }
                let line = firstLine()
                if line.length > 0 {
                    inserted.addAttribute(.paragraphStyle, value: RichTextAttributed.paragraphStyle(list: target), range: line)
                }
            }
        }
        guard let storage = textStorage, shouldChangeText(in: range, replacementString: inserted.string) else { return }
        storage.replaceCharacters(in: range, with: inserted)
        setSelectedRange(NSRange(location: range.location + inserted.length, length: 0))
        didChangeText()
    }
}
