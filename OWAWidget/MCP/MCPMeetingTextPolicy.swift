import Foundation

/// What `create_meeting` accepts as text, so the confirmation panel shows what is actually sent.
///
/// The arguments come from an AI client, which may be steered by text someone else wrote (a
/// meeting description, a web page). The panel is the user's only look at the meeting before it
/// goes out, so text that renders differently from its content is refused or flagged:
/// - bidirectional controls (RLO and friends) reorder what is displayed — `moc.live@ivan` shows
///   as `ivan@evil.com` — and plain meeting text never needs them: refused;
/// - other invisible format characters (zero-width spaces, BOM) can hide words or split a link:
///   allowed, since a zero-width joiner is part of many emoji, but the panel warns about them;
/// - addresses must be plain ASCII: Exchange addresses are, and a lookalike Cyrillic letter in a
///   domain is otherwise invisible when the panel cannot tell internal from external.
enum MCPMeetingTextPolicy {
    /// U+202A–U+202E (embeddings, overrides) and U+2066–U+2069 (isolates).
    static func containsBidiControls(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x202A...0x202E).contains($0.value) || (0x2066...0x2069).contains($0.value) }
    }

    /// Invisible format characters other than the joiners emoji and some scripts rely on.
    static func containsHiddenCharacters(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            guard scalar.properties.generalCategory == .format else { return false }
            switch scalar.value {
            case 0x200C, 0x200D: return false // ZWNJ / ZWJ: emoji sequences, Persian and Indic text
            case 0xE0020...0xE007F: return false // tag characters: subdivision flag emoji
            default: return true
            }
        }
    }

    /// Printable ASCII only, no spaces.
    static func isPlainASCIIAddress(_ email: String) -> Bool {
        email.unicodeScalars.allSatisfy { (0x21...0x7E).contains($0.value) }
    }

    /// Runs of blank lines collapse to one: a long gap in the middle of an agenda would push its
    /// tail out of the panel's view. Applied to what is sent, not only to what is shown, so the
    /// two stay the same.
    static func normalizedAgenda(_ agenda: String) -> String {
        var lines: [String] = []
        for line in agenda.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let isBlank = line.trimmingCharacters(in: .whitespaces).isEmpty
            if isBlank, lines.last.map({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? true { continue }
            lines.append(isBlank ? "" : line)
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
