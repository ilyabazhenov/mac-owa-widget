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
enum MeetingBodyHTMLConverter {

    static func looksLikeHTML(_ string: String) -> Bool {
        guard string.contains("<") else { return false }
        return tagPattern.firstMatch(
            in: string,
            range: NSRange(location: 0, length: (string as NSString).length)
        ) != nil
    }

    static func plainText(from html: String) -> String {
        var text = html
        text = replace(in: text, pattern: dropWholeElementsPattern, with: " ")
        text = expandAnchors(in: text)
        text = replace(in: text, pattern: lineBreakPattern, with: "\n")
        text = replace(in: text, pattern: tagPattern, with: "")
        text = decodeEntities(in: text)
        return normalizeWhitespace(text)
    }

    // MARK: - Steps

    /// `<a href="…">text</a>` → `text` when the text already shows the URL, otherwise `text (URL)`.
    private static func expandAnchors(in html: String) -> String {
        let ns = html as NSString
        let matches = anchorPattern.matches(in: html, range: NSRange(location: 0, length: ns.length))
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

    private static func decodeEntities(in string: String) -> String {
        guard string.contains("&") else { return string }
        var result = string
        for (entity, replacement) in namedEntities {
            result = result.replacingOccurrences(of: entity, with: replacement, options: .caseInsensitive)
        }
        result = replaceMatches(in: result, pattern: numericEntityPattern) { match, ns in
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
            let line = rawLine
                .replacingOccurrences(of: "[ \t]+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            if line.isEmpty, lines.last?.isEmpty == true { continue }
            lines.append(line)
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Regex helpers

    private static func replace(in string: String, pattern: NSRegularExpression, with template: String) -> String {
        let ns = string as NSString
        return pattern.stringByReplacingMatches(
            in: string,
            range: NSRange(location: 0, length: ns.length),
            withTemplate: template
        )
    }

    /// Replacement driven by a closure; returning `nil` keeps the original match untouched.
    private static func replaceMatches(
        in string: String,
        pattern: NSRegularExpression,
        transform: (NSTextCheckingResult, NSString) -> String?
    ) -> String {
        let ns = string as NSString
        let matches = pattern.matches(in: string, range: NSRange(location: 0, length: ns.length))
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

    private static let dropWholeElementsPattern = regex(
        #"<!--.*?-->|<style\b[^>]*>.*?</style>|<script\b[^>]*>.*?</script>|<head\b[^>]*>.*?</head>"#
    )
    private static let anchorPattern = regex(#"<a\b[^>]*?href\s*=\s*["']([^"']*)["'][^>]*>(.*?)</a>"#)
    private static let lineBreakPattern = regex(#"<br\b[^>]*>|</p>|</div>|</tr>|</li>|</h[1-6]>"#)
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
