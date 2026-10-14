import Foundation

/// Converts an Exchange meeting body from HTML into plain text for the detail panel.
///
/// The full body (unlike the 255-character `Preview` that the sync request returns) arrives as a
/// complete HTML document — `<head>`, `<meta>` and a `<style>` block included. In a captured
/// response 5242 bytes of HTML carried only ~530 characters of actual text, the rest being CSS,
/// so `<style>`/`<script>`/`<head>` are dropped wholesale before tags are stripped; otherwise the
/// stylesheet leaks into the description.
///
/// Anchors keep their destination: when the visible text is not the URL itself, the `href` is
/// appended in parentheses so `MeetingBodyLinkFormatter` can still make it clickable.
///
/// Agendas are structured documents, so structure is preserved as far as plain text allows:
/// a table row stays on one line with `|` between cells, and list items keep `•` / `◦` markers
/// matching the nesting OWA renders.
enum MeetingBodyHTMLConverter {

    static func looksLikeHTML(_ string: String) -> Bool {
        guard string.contains("<") else { return false }
        let ns = string as NSString
        guard let range = searchRange(endingAtLastOf: [">"], in: ns) else { return false }
        return tagPattern.firstMatch(in: string, range: range) != nil
    }

    static func plainText(from html: String) -> String {
        var text = html
        for (pattern, closing) in droppedElements {
            text = replace(in: text, pattern: pattern, with: " ", closings: [closing])
        }
        // Outlook hard-wraps the *markup* at ~70 columns. In HTML those newlines are ordinary
        // whitespace, so they must collapse to spaces — keeping them split sentences mid-phrase
        // ("Дерево контактов. Исключения\n(доработка)"). Every line break below comes from a tag.
        text = replace(in: text, pattern: sourceNewlinePattern, with: " ", closings: nil)
        text = expandAnchors(in: text)
        // Outlook wraps the content of every cell and list item in its own <p>. Left alone, that
        // paragraph break fires before the cell separator does and a table row falls apart into one
        // line per cell — so inside cells and bullets the block tags are flattened to spaces first.
        text = flattenBlockTags(in: text, insideElementsMatching: cellContentPattern, closings: ["</td>", "</th>"])
        text = flattenBlockTags(in: text, insideElementsMatching: listItemContentPattern, closings: ["</li>"])
        text = markListItems(in: text)
        text = replace(in: text, pattern: cellPattern, with: cellSeparator)
        text = replace(in: text, pattern: paragraphPattern, with: "\n\n")
        text = replace(in: text, pattern: lineBreakPattern, with: "\n")
        text = replace(in: text, pattern: tagPattern, with: "")
        text = decodeEntities(in: text)
        return normalizeWhitespace(text)
    }

    // MARK: - Steps

    /// `<a href="…">text</a>` → `text` when the text already shows the URL, otherwise `text (URL)`.
    private static func expandAnchors(in html: String) -> String {
        let ns = html as NSString
        guard let range = searchRange(endingAtLastOf: ["</a>"], in: ns) else { return html }
        let matches = anchorPattern.matches(in: html, range: range)
        guard !matches.isEmpty else { return html }

        var result = ""
        var cursor = 0
        for match in matches where match.range.location >= cursor {
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))

            // Both parts stay HTML-encoded here; entity decoding happens once, globally, at the
            // end — decoding twice would turn a literal "&amp;lt;" into a live "<".
            let href = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            let inner = normalizeWhitespace(replace(in: ns.substring(with: match.range(at: 2)), pattern: tagPattern, with: ""))

            if inner.isEmpty {
                result += href
            } else if href.isEmpty || inner.localizedCaseInsensitiveContains(href) {
                result += inner
            } else {
                result += "\(inner) (\(href))"
            }
            cursor = match.range.location + match.range.length
        }
        if cursor < ns.length {
            result += ns.substring(from: cursor)
        }
        return result
    }

    /// Turns `<li>` into a bullet on its own line, tracking list nesting so sub-items get the
    /// hollow marker OWA itself renders. Markers carry the hierarchy instead of indentation:
    /// leading spaces would be trimmed away by the line normalization.
    private static func markListItems(in html: String) -> String {
        var depth = 0
        return replaceMatches(in: html, pattern: listStructurePattern, closings: [">"]) { match, ns in
            let tag = ns.substring(with: match.range).lowercased()
            if tag.hasPrefix("</") {
                depth = max(0, depth - 1)
                return "\n"
            }
            if tag.hasPrefix("<u") || tag.hasPrefix("<o") {
                depth += 1
                return " "
            }
            return "\n" + (depth > 1 ? nestedBulletPrefix : bulletPrefix)
        }
    }

    /// Replaces `<p>`/`<div>`/`<br>` with spaces, but only within the elements the pattern matches.
    private static func flattenBlockTags(
        in html: String,
        insideElementsMatching pattern: NSRegularExpression,
        closings: [String]
    ) -> String {
        replaceMatches(in: html, pattern: pattern, closings: closings) { match, ns in
            replace(in: ns.substring(with: match.range), pattern: innerBlockTagPattern, with: " ")
        }
    }

    private static func decodeEntities(in string: String) -> String {
        guard string.contains("&") else { return string }
        var result = string
        for (entity, replacement) in namedEntities {
            result = result.replacingOccurrences(of: entity, with: replacement, options: .caseInsensitive)
        }
        result = replaceMatches(in: result, pattern: numericEntityPattern, closings: [";"]) { match, ns in
            let isHex = !ns.substring(with: match.range(at: 1)).isEmpty
            let digits = ns.substring(with: match.range(at: 2))
            guard let code = UInt32(digits, radix: isHex ? 16 : 10), let scalar = Unicode.Scalar(code) else {
                return nil
            }
            return String(Character(scalar))
        }
        return result
    }

    /// Trims each line, drops runs of blank lines (HTML mail is full of empty `<p>`s) and
    /// normalizes the non-breaking spaces Outlook sprinkles into text.
    private static func normalizeWhitespace(_ string: String) -> String {
        let unified = string
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var lines: [String] = []
        for rawLine in unified.components(separatedBy: "\n") {
            var line = rawLine
                .replacingOccurrences(of: "[ \t]+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            if line.contains("|") {
                // Empty cells collapse, and a row never starts or ends with a dangling separator.
                line = line
                    .replacingOccurrences(of: #"\s*\|(\s*\|)+\s*"#, with: cellSeparator, options: .regularExpression)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "| "))
            }
            // An empty <li> would otherwise leave a lone bullet behind.
            if line == bulletPrefix.trimmingCharacters(in: .whitespaces)
                || line == nestedBulletPrefix.trimmingCharacters(in: .whitespaces) { continue }
            if line.isEmpty, lines.last?.isEmpty == true { continue }
            lines.append(line)
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Regex helpers

    /// The part of `ns` up to the end of the last of `closings`, or `nil` when none occurs.
    ///
    /// Every pattern here ends in a fixed token (`>`, `</li>`, `-->`…). A match that never finds it
    /// (`.*?`, `[^>]*`) scans to the end of the input and fails, and the engine then retries from
    /// the next opening — n openings × n characters. Meeting bodies come from anyone who can send
    /// an invitation: 100 KB of unclosed `<!--` took 28 s, on the main thread. Ending the search at
    /// the last closing token means every attempt that gets past its opening succeeds, so each
    /// character is consumed once.
    static func searchRange(endingAtLastOf closings: [String], in ns: NSString) -> NSRange? {
        let end = closings.compactMap { closing -> Int? in
            let found = ns.range(of: closing, options: [.backwards, .caseInsensitive])
            return found.location == NSNotFound ? nil : found.location + found.length
        }.max()
        return end.map { NSRange(location: 0, length: $0) }
    }

    /// `closings`: what every match of `pattern` ends with, see ``searchRange(endingAtLastOf:in:)``;
    /// `nil` for a pattern with no unbounded part.
    private static func replace(
        in string: String,
        pattern: NSRegularExpression,
        with template: String,
        closings: [String]? = [">"]
    ) -> String {
        let ns = string as NSString
        let range: NSRange
        if let closings {
            guard let bounded = searchRange(endingAtLastOf: closings, in: ns) else { return string }
            range = bounded
        } else {
            range = NSRange(location: 0, length: ns.length)
        }
        return pattern.stringByReplacingMatches(in: string, range: range, withTemplate: template)
    }

    /// Replacement driven by a closure; returning `nil` keeps the original match untouched.
    private static func replaceMatches(
        in string: String,
        pattern: NSRegularExpression,
        closings: [String],
        transform: (NSTextCheckingResult, NSString) -> String?
    ) -> String {
        let ns = string as NSString
        guard let range = searchRange(endingAtLastOf: closings, in: ns) else { return string }
        let matches = pattern.matches(in: string, range: range)
        guard !matches.isEmpty else { return string }

        var result = ""
        var cursor = 0
        for match in matches where match.range.location >= cursor {
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            result += transform(match, ns) ?? ns.substring(with: match.range)
            cursor = match.range.location + match.range.length
        }
        if cursor < ns.length {
            result += ns.substring(from: cursor)
        }
        return result
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // Patterns are literals owned by this file; a failure here is a programming error.
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
    }

    /// Agenda tables are common in invites; a row kept on one line stays readable in the narrow
    /// panel, whereas one cell per line (the naive rendering) turns a 3×4 table into 12 lines.
    static let cellSeparator = " | "
    static let bulletPrefix = "• "
    static let nestedBulletPrefix = "◦ "

    /// Elements dropped with their content, each searched on its own up to its own closing tag
    /// (see ``searchRange(endingAtLastOf:in:)``). Inside an opening tag `[^<>]` rather than `[^>]`:
    /// a run of `<a x` with no `>` must not let every attempt scan to the next distant `>`.
    private static let droppedElements: [(NSRegularExpression, String)] = [
        (regex(#"<!--.*?-->"#), "-->"),
        (regex(#"<style\b[^<>]*>.*?</style>"#), "</style>"),
        (regex(#"<script\b[^<>]*>.*?</script>"#), "</script>"),
        (regex(#"<head\b[^<>]*>.*?</head>"#), "</head>"),
    ]
    private static let sourceNewlinePattern = regex(#"[\r\n\t]+"#)
    private static let anchorPattern = regex(#"<a\b[^<>]*?href\s*=\s*["']([^"']*)["'][^<>]*>(.*?)</a>"#)
    private static let cellContentPattern = regex(#"<t[dh]\b[^<>]*>.*?</t[dh]>"#)
    private static let listItemContentPattern = regex(#"<li\b[^<>]*>.*?</li>"#)
    private static let innerBlockTagPattern = regex(#"</?p\b[^>]*>|</?div\b[^>]*>|<br\b[^>]*>"#)
    private static let listStructurePattern = regex(#"<ul\b[^>]*>|<ol\b[^>]*>|</ul>|</ol>|<li\b[^>]*>"#)
    private static let cellPattern = regex(#"</t[dh]>"#)
    private static let paragraphPattern = regex(#"</p>"#)
    // `</li>`, `</ul>` and `</ol>` are deliberately absent — `markListItems` already handles them.
    // Closing a list item here too would leave a blank line between every bullet.
    private static let lineBreakPattern = regex(#"<br\b[^>]*>|</div>|</tr>|</h[1-6]>"#)
    private static let tagPattern = regex(#"<[^>]+>"#)
    private static let numericEntityPattern = regex(#"&#(x?)([0-9a-f]+);"#)

    private static let namedEntities: [(String, String)] = [
        ("&nbsp;", " "), ("&quot;", "\""), ("&apos;", "'"),
        ("&laquo;", "«"), ("&raquo;", "»"), ("&mdash;", "—"), ("&ndash;", "–"),
        ("&hellip;", "…"), ("&bull;", "•"),
        ("&lsquo;", "‘"), ("&rsquo;", "’"), ("&ldquo;", "“"), ("&rdquo;", "”"),
        ("&lt;", "<"), ("&gt;", ">"),
        // Ampersand last: decoding it first would turn "&amp;lt;" into a live "<".
        ("&amp;", "&"),
    ]
}
