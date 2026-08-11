import AppKit

/// Builds the meeting body as an `NSAttributedString`.
///
/// The SwiftUI rendering (a `VStack` of `Text` rows) had two flaws no modifier can fix: selection
/// never crossed a row boundary, and `Grid` splits width evenly, so a three-column agenda squeezed
/// the task column into two words per line. AppKit solves both natively — one text run means one
/// selection, and `NSTextTable` sizes columns by their content.
///
/// The string is composed here rather than via `NSAttributedString(html:)`: that importer pulls
/// remote resources (tracking pixels in an invite would fire) and carries the sender's fonts and
/// colours, which break the panel's typography in dark mode.
enum MeetingBodyAttributedBuilder {

    static func attributedString(
        for nodes: [MeetingBodyDocument.Node],
        font: NSFont,
        color: NSColor,
        linkColor: NSColor
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for node in nodes {
            switch node.kind {
            case .text(let text):
                append(
                    blocks: MeetingBodyLayout.blocks(from: text),
                    to: result,
                    font: font, color: color, linkColor: linkColor,
                    textBlock: nil, isBold: false
                )
            case .table(let table):
                append(table: table, to: result, font: font, color: color, linkColor: linkColor)
            }
        }
        trimTrailingNewline(result)
        return result
    }

    // MARK: - Blocks

    private static func append(
        blocks: [MeetingBodyLayout.Block],
        to result: NSMutableAttributedString,
        font: NSFont,
        color: NSColor,
        linkColor: NSColor,
        textBlock: NSTextTableBlock?,
        isBold: Bool
    ) {
        for block in blocks {
            let style = NSMutableParagraphStyle()
            style.paragraphSpacing = textBlock == nil ? 4 : 0
            style.paragraphSpacingBefore = block.hasGapBefore ? 6 : 0
            if let textBlock {
                style.textBlocks = [textBlock]
            }

            var line = block.text
            if case .bullet(let level) = block.kind {
                let marker = level > 1 ? MeetingBodyHTMLConverter.nestedBulletPrefix : MeetingBodyHTMLConverter.bulletPrefix
                line = marker + line
                // Hanging indent: the wrapped part of a bullet lines up under its text, not under
                // the marker, so a long item cannot be mistaken for two items.
                let indent = CGFloat(level - 1) * 12
                style.firstLineHeadIndent = indent
                style.headIndent = indent + 13
            }

            let paragraphStart = result.length
            result.append(NSAttributedString(
                string: line + "\n",
                attributes: [
                    .font: isBold ? bold(font) : font,
                    .foregroundColor: color,
                    .paragraphStyle: style,
                ]
            ))
            applyLinks(in: line, paragraphStart: paragraphStart, to: result, linkColor: linkColor)
        }
    }

    private static func applyLinks(
        in line: String,
        paragraphStart: Int,
        to result: NSMutableAttributedString,
        linkColor: NSColor
    ) {
        for link in MeetingBodyLinkFormatter.detectLinks(in: line) {
            let range = NSRange(location: paragraphStart + link.range.location, length: link.range.length)
            guard NSMaxRange(range) <= result.length else { continue }
            result.addAttributes(
                [.link: link.url, .foregroundColor: linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue],
                range: range
            )
        }
    }

    // MARK: - Tables

    private static func append(
        table: MeetingBodyDocument.Table,
        to result: NSMutableAttributedString,
        font: NSFont,
        color: NSColor,
        linkColor: NSColor
    ) {
        let textTable = NSTextTable()
        textTable.numberOfColumns = table.columnCount
        // Automatic layout is HTML-like: columns get width in proportion to their content, so the
        // short "block"/"timing" cells stay narrow and the task column keeps the rest.
        textTable.layoutAlgorithm = .automaticLayoutAlgorithm
        textTable.collapsesBorders = true
        textTable.hidesEmptyCells = false

        for (rowIndex, cells) in table.rows.enumerated() {
            for columnIndex in 0..<table.columnCount {
                let cell = columnIndex < cells.count ? cells[columnIndex] : ""
                let block = NSTextTableBlock(
                    table: textTable,
                    startingRow: rowIndex,
                    rowSpan: 1,
                    startingColumn: columnIndex,
                    columnSpan: 1
                )
                block.setContentWidth(100, type: .percentageValueType)
                block.setWidth(6, type: .absoluteValueType, for: .padding)
                // A hairline under every row but the last: enough to read as a table without the
                // heavy full grid an invite would otherwise draw in a narrow panel.
                if rowIndex < table.rows.count - 1 {
                    block.setWidth(1, type: .absoluteValueType, for: .border, edge: .maxY)
                    block.setBorderColor(.separatorColor)
                }

                // A cell must contribute at least one paragraph, otherwise its row collapses.
                var blocks = MeetingBodyLayout.blocks(from: cell)
                if blocks.isEmpty {
                    blocks = [MeetingBodyLayout.Block(id: 0, kind: .paragraph, text: "", hasGapBefore: false)]
                }
                append(
                    blocks: blocks,
                    to: result,
                    font: font, color: color, linkColor: linkColor,
                    textBlock: block,
                    isBold: rowIndex == 0 && table.hasHeaderRow
                )
            }
        }
    }

    // MARK: - Helpers

    private static func bold(_ font: NSFont) -> NSFont {
        NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
    }

    /// Drops the trailing paragraph break so the body does not end with a blank line — unless the
    /// document ends with a table, where every cell needs its terminator to lay out.
    private static func trimTrailingNewline(_ string: NSMutableAttributedString) {
        guard string.length > 0, string.string.hasSuffix("\n") else { return }
        let style = string.attribute(.paragraphStyle, at: string.length - 1, effectiveRange: nil) as? NSParagraphStyle
        guard style?.textBlocks.isEmpty != false else { return }
        string.deleteCharacters(in: NSRange(location: string.length - 1, length: 1))
    }
}
