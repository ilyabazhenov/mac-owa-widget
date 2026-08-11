import Foundation

/// Finds the clickable links in a meeting body.
///
/// Bodies reach the UI as plain text (HTML tags are stripped in the provider), so no `href`
/// survives — links have to be recovered from the text itself. `NSDataDetector` is used instead
/// of a hand-rolled regex because corporate wikis produce non-ASCII paths
/// (`…/PreSA.+Автоматическая+передача…`) that a naive `[^\s]+` pattern mangles.
///
/// Every candidate goes through `MeetingURLOpener.safeURL`, so only `https` links become
/// clickable: calendar bodies are server-controlled data and must not be able to put a
/// `file://` (or custom-scheme) link in front of the user.
///
/// The ranges land on the rendered text as `.link` attributes — see `MeetingBodyAttributedBuilder`.
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

    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
}
