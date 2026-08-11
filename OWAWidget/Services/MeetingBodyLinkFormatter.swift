import Foundation

/// Turns a meeting body into an `AttributedString` whose links are clickable.
///
/// Bodies reach the UI as plain text (HTML tags are stripped in the provider), so no `href`
/// survives — links have to be recovered from the text itself. `NSDataDetector` is used instead
/// of a hand-rolled regex because corporate wikis produce non-ASCII paths
/// (`…/PreSA.+Автоматическая+передача…`) that a naive `[^\s]+` pattern mangles.
///
/// Every candidate goes through `MeetingURLOpener.safeURL`, so only `https` links become
/// clickable: calendar bodies are server-controlled data and must not be able to put a
/// `file://` (or custom-scheme) link in front of the user.
enum MeetingBodyLinkFormatter {

    struct DetectedLink: Equatable {
        /// Range in the original string, in UTF-16 units (`NSString` semantics).
        let range: NSRange
        /// The text as written in the body — kept verbatim so the user sees what they can copy.
        let text: String
        /// Normalized, scheme-checked destination.
        let url: URL
    }

    static func detectLinks(in text: String) -> [DetectedLink] {
        guard let detector, !text.isEmpty else { return [] }
        let ns = text as NSString
        let matches = detector.matches(in: text, range: NSRange(location: 0, length: ns.length))
        return matches.compactMap { match in
            guard let url = match.url, let safe = MeetingURLOpener.safeURL(from: url) else { return nil }
            return DetectedLink(range: match.range, text: ns.substring(with: match.range), url: safe)
        }
    }

    /// Builds the string piecewise (plain chunk, link chunk, plain chunk, …) rather than applying
    /// attributes to ranges after the fact: `NSRange` → `AttributedString.Index` conversion is the
    /// usual source of off-by-one bugs once the body contains emoji or other non-BMP characters.
    static func attributedBody(_ text: String) -> AttributedString {
        let ns = text as NSString
        var result = AttributedString()
        var cursor = 0

        for link in detectLinks(in: text) {
            // Detected ranges are ordered and non-overlapping; the guard keeps a malformed
            // match from producing duplicated text.
            guard link.range.location >= cursor else { continue }
            if link.range.location > cursor {
                let plain = ns.substring(with: NSRange(location: cursor, length: link.range.location - cursor))
                result.append(AttributedString(plain))
            }
            var run = AttributedString(link.text)
            run.link = link.url
            result.append(run)
            cursor = link.range.location + link.range.length
        }

        if cursor < ns.length {
            result.append(AttributedString(ns.substring(from: cursor)))
        }
        return result
    }

    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
}
