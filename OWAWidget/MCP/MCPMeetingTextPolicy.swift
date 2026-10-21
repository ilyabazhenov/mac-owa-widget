import Foundation

/// What `create_meeting` accepts as text, so the confirmation panel shows what is actually sent.
///
/// The arguments come from an AI client, which may be steered by text someone else wrote (a
/// meeting description, a web page). The panel is the user's only look at the meeting before it
/// goes out, so text that renders differently from its content is refused or flagged:
/// - bidirectional controls (RLO and friends) reorder what is displayed — `moc.live@ivan` shows
///   as `ivan@evil.com` — and plain meeting text never needs them: refused;
/// - other invisible characters (zero-width spaces, BOM, Unicode tags, variation selectors,
///   Hangul fillers, C1 controls) draw nothing and leave the character count alone, so a short
///   visible line can carry any amount of hidden text to the recipient: refused. Only joiners,
///   variation selectors and tags where emoji need them pass;
/// - spaces that look like a plain space (no-break, en, thin…) become one, and spaces at line
///   ends go: either way they could carry text the panel does not show;
/// - addresses must be plain ASCII: Exchange addresses are, and a lookalike Cyrillic letter in a
///   domain is otherwise invisible when the panel cannot tell internal from external.
enum MCPMeetingTextPolicy {
    /// U+202A–U+202E (embeddings, overrides) and U+2066–U+2069 (isolates).
    static func containsBidiControls(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x202A...0x202E).contains($0.value) || (0x2066...0x2069).contains($0.value) }
    }

    /// Characters that draw nothing, other than the joiners, variation selectors and tags inside
    /// the emoji and scripts that need them.
    static func containsHiddenCharacters(_ text: String) -> Bool {
        let scalars = Array(text.unicodeScalars)
        let flagTags = subdivisionFlagTags(scalars)
        for (index, scalar) in scalars.enumerated() {
            let value = scalar.value
            if scalar.properties.generalCategory == .control {
                if value == 0x09 || value == 0x0A || value == 0x0D { continue }
                return true
            }
            guard scalar.properties.isDefaultIgnorableCodePoint else { continue }
            let previous = index > 0 ? scalars[index - 1] : nil
            let next = index + 1 < scalars.count ? scalars[index + 1] : nil
            switch value {
            case 0x200C, 0x200D:
                // ZWNJ / ZWJ: between letters of scripts that shape with them (Persian, Indic),
                // and ZWJ between the parts of an emoji sequence.
                if let previous, let next, usesJoiners(previous), usesJoiners(next) { continue }
                if value == 0x200D, let previous, let next, isEmojiPart(previous), next.properties.isEmoji { continue }
                return true
            case 0xFE0E, 0xFE0F:
                // Text or emoji presentation, once, right after a character that has both.
                if let previous, previous.properties.isEmoji, !previous.properties.isDefaultIgnorableCodePoint { continue }
                return true
            default:
                if flagTags.contains(index) { continue }
                return true
            }
        }
        return false
    }

    /// Spaces that look like a plain one become one, trailing spaces go: the panel cannot show
    /// either difference, and the recipient's mail source keeps both.
    static func normalizedSpaces(_ line: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in line.unicodeScalars {
            switch scalar.value {
            case 0x00A0, 0x2000...0x200A, 0x202F, 0x205F: scalars.append(" ")
            default: scalars.append(scalar)
            }
        }
        var result = String(scalars)
        while let last = result.unicodeScalars.last, last.properties.isWhitespace, !CharacterSet.newlines.contains(last) {
            result.unicodeScalars.removeLast()
        }
        return result
    }

    /// A line of spaces, controls or characters that draw nothing (U+2800 is a blank Braille cell).
    static func isBlankLine(_ line: String) -> Bool {
        line.unicodeScalars.allSatisfy { scalar in
            scalar.properties.isWhitespace || scalar.properties.isDefaultIgnorableCodePoint
                || scalar.properties.generalCategory == .control || scalar.value == 0x2800
        }
    }

    /// Positions of the tag characters in subdivision flags: 🏴, 1–7 tag letters or digits, CANCEL TAG.
    private static func subdivisionFlagTags(_ scalars: [Unicode.Scalar]) -> Set<Int> {
        var allowed: Set<Int> = []
        for (index, scalar) in scalars.enumerated() where scalar.value == 0x1F3F4 {
            var end = index + 1
            while end < scalars.count, end - index <= 7,
                  (0xE0030...0xE0039).contains(scalars[end].value) || (0xE0061...0xE007A).contains(scalars[end].value) {
                end += 1
            }
            guard end > index + 1, end < scalars.count, scalars[end].value == 0xE007F else { continue }
            allowed.formUnion(index + 1...end)
        }
        return allowed
    }

    /// Arabic-script and Indic letters and marks, where ZWJ and ZWNJ change how text is drawn.
    private static func usesJoiners(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0600...0x06FF, 0x0750...0x077F, 0x08A0...0x08FF, 0xFB50...0xFDFF, 0xFE70...0xFEFE, 0x0900...0x0DFF:
            return scalar.properties.isAlphabetic || scalar.properties.generalCategory == .nonspacingMark
                || scalar.properties.generalCategory == .spacingMark
        default:
            return false
        }
    }

    private static func isEmojiPart(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isEmoji || scalar.properties.isEmojiModifier || scalar.value == 0xFE0F
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
        // Every line separator, not only "\n": U+2028, U+2029, NEL or a bare CR stack up blank
        // space just as well. CRLF first, so it counts as one break rather than two.
        let unified = agenda.replacingOccurrences(of: "\r\n", with: "\n")
        for line in unified.components(separatedBy: .newlines) {
            let isBlank = isBlankLine(line)
            if isBlank, lines.last?.isEmpty ?? true { continue }
            lines.append(isBlank ? "" : normalizedSpaces(line))
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
