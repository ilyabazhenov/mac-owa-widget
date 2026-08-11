import AppKit

/// Turns what the server gave us into the string the detail panel shows.
///
/// The two inputs are independent: the plain text always exists (it is what the sync request
/// caches and what a restart restores), while the markup is only around for as long as the details
/// stay in memory. Tables need the markup, so it wins whenever it is there.
///
/// Lives outside the view so the choice between the two paths is testable — the view only stores
/// the result.
enum MeetingBodyRenderer {

    /// Panel body size. Resolved per call rather than stored: `NSFont` is not `Sendable`, so a
    /// static instance would be shared mutable state under strict concurrency.
    static var font: NSFont { .systemFont(ofSize: 12) }

    static func attributedBody(text: String?, html: String?) -> NSAttributedString? {
        attributedBody(text: text, html: html, font: font, color: .secondaryLabelColor, linkColor: .linkColor)
    }

    static func attributedBody(
        text: String?,
        html: String?,
        font: NSFont,
        color: NSColor,
        linkColor: NSColor
    ) -> NSAttributedString? {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }

        let nodes = html.map(MeetingBodyDocument.nodes(fromHTML:))
            ?? MeetingBodyDocument.nodes(fromPlainText: trimmed)
        let result = MeetingBodyAttributedBuilder.attributedString(
            for: nodes,
            font: font,
            color: color,
            linkColor: linkColor
        )
        return result.length > 0 ? result : nil
    }
}
