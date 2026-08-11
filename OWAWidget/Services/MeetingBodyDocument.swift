import Foundation

/// A meeting body split into renderable nodes: running text and real tables.
///
/// Agendas are very often a timetable. Flattening one into `cell | cell | cell` text keeps it
/// readable but loses the grid, so the HTML is parsed once more — this time only for table
/// structure — and everything between tables goes through the usual HTML→text conversion.
enum MeetingBodyDocument {

    struct Node: Identifiable, Equatable {
        enum Kind: Equatable {
            /// Plain text; the view lays it out with `MeetingBodyLayout`.
            case text(String)
            case table(Table)
        }

        let id: Int
        let kind: Kind
    }

    struct Table: Equatable {
        /// Cell contents as plain text; a cell may itself hold several lines and bullet markers.
        let rows: [[String]]
        /// The first row is a header (short, single-line cells with data rows beneath it).
        let hasHeaderRow: Bool

        var columnCount: Int { rows.map(\.count).max() ?? 0 }
    }

    /// Wider tables are not worth rendering as a grid in a ~300pt panel — each column would be a
    /// few characters across. Those fall back to the flattened text form.
    static let maxRenderableColumns = 4

    /// Header heuristic: Outlook builds header rows out of ordinary `<td>`s, so the tag alone
    /// cannot be trusted — a first row of short, single-line labels above real rows is the signal.
    static let maxHeaderCellLength = 24

    static func nodes(fromHTML html: String) -> [Node] {
        var kinds: [Node.Kind] = []

        for segment in HTMLTableScanner.segments(in: html) {
            switch segment {
            case .text(let raw):
                appendText(MeetingBodyHTMLConverter.plainText(from: raw), to: &kinds)
            case .table(let raw):
                let table = parseTable(raw)
                if let table, table.columnCount <= maxRenderableColumns {
                    kinds.append(.table(table))
                } else {
                    appendText(MeetingBodyHTMLConverter.plainText(from: raw), to: &kinds)
                }
            }
        }

        return kinds.enumerated().map { Node(id: $0.offset, kind: $0.element) }
    }

    static func nodes(fromPlainText text: String) -> [Node] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? [] : [Node(id: 0, kind: .text(trimmed))]
    }

    // MARK: - Parsing

    private static func appendText(_ text: String, to kinds: inout [Node.Kind]) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Text split by a table on either side still belongs to one flow when the table was
        // dropped, so neighbouring text nodes merge instead of stacking with a double gap.
        if case .text(let previous)? = kinds.last {
            kinds[kinds.count - 1] = .text(previous + "\n\n" + trimmed)
        } else {
            kinds.append(.text(trimmed))
        }
    }

    private static func parseTable(_ html: String) -> Table? {
        let rows = HTMLTableScanner.rows(in: html)
            .map { $0.map { cellText(from: $0) } }
            .filter { row in row.contains { !$0.isEmpty } }
        guard !rows.isEmpty else { return nil }
        return Table(rows: rows, hasHeaderRow: looksLikeHeader(rows))
    }

    /// Inside a cell an empty paragraph is just noise — a cell is a few lines, not a document.
    private static func cellText(from html: String) -> String {
        MeetingBodyHTMLConverter.plainText(from: html)
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .joined(separator: "\n")
    }

    private static func looksLikeHeader(_ rows: [[String]]) -> Bool {
        guard rows.count > 1, let first = rows.first, first.count > 1 else { return false }
        return first.allSatisfy { cell in
            !cell.contains("\n") && cell.count <= maxHeaderCellLength
        }
    }
}

/// Minimal, depth-aware scanner for `<table>` / `<tr>` / `<td>` structure. A full HTML parser is
/// not needed: everything inside a cell is handed to the text converter anyway. Depth tracking
/// matters because Outlook nests tables for layout — a naive non-greedy regex would end the outer
/// row at the inner table's first `</td>`.
enum HTMLTableScanner {

    enum Segment: Equatable {
        case text(String)
        case table(String)
    }

    static func segments(in html: String) -> [Segment] {
        let ns = html as NSString
        var segments: [Segment] = []
        var depth = 0
        var cursor = 0
        var tableStart = 0

        for match in tokens(tablePattern, in: html) {
            let tag = ns.substring(with: match.range).lowercased()
            if tag.hasPrefix("</") {
                guard depth > 0 else { continue }
                depth -= 1
                if depth == 0 {
                    let end = match.range.location + match.range.length
                    segments.append(.table(ns.substring(with: NSRange(location: tableStart, length: end - tableStart))))
                    cursor = end
                }
            } else {
                if depth == 0 {
                    if match.range.location > cursor {
                        let length = match.range.location - cursor
                        segments.append(.text(ns.substring(with: NSRange(location: cursor, length: length))))
                    }
                    tableStart = match.range.location
                }
                depth += 1
            }
        }

        if cursor < ns.length {
            segments.append(.text(ns.substring(from: cursor)))
        }
        return segments
    }

    /// Cells of the outermost table only; a nested table stays inside its parent cell as markup.
    static func rows(in tableHTML: String) -> [[String]] {
        let ns = tableHTML as NSString
        var rows: [[String]] = []
        var currentRow: [String] = []
        var cellStart: Int?
        var tableDepth = 0

        for match in tokens(cellPattern, in: tableHTML) {
            let tag = ns.substring(with: match.range).lowercased()
            let end = match.range.location + match.range.length

            if tag.hasPrefix("<table") {
                tableDepth += 1
                continue
            }
            if tag.hasPrefix("</table") {
                tableDepth = max(0, tableDepth - 1)
                continue
            }
            // Everything below belongs to a nested table — leave it inside the current cell.
            guard tableDepth <= 1 else { continue }

            if tag.hasPrefix("<tr") {
                currentRow = []
            } else if tag.hasPrefix("</tr") {
                if !currentRow.isEmpty { rows.append(currentRow) }
                currentRow = []
            } else if tag.hasPrefix("<td") || tag.hasPrefix("<th") {
                cellStart = end
            } else if tag.hasPrefix("</td") || tag.hasPrefix("</th") {
                guard let start = cellStart, match.range.location >= start else { continue }
                let length = match.range.location - start
                currentRow.append(ns.substring(with: NSRange(location: start, length: length)))
                cellStart = nil
            }
        }

        if !currentRow.isEmpty { rows.append(currentRow) }
        return rows
    }

    private static func tokens(_ pattern: NSRegularExpression, in html: String) -> [NSTextCheckingResult] {
        pattern.matches(in: html, range: NSRange(location: 0, length: (html as NSString).length))
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // Literal owned by this file; a failure here is a programming error.
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
    }

    private static let tablePattern = regex(#"<table\b[^>]*>|</table>"#)
    private static let cellPattern = regex(#"<table\b[^>]*>|</table>|<tr\b[^>]*>|</tr>|<t[dh]\b[^>]*>|</t[dh]>"#)
}
