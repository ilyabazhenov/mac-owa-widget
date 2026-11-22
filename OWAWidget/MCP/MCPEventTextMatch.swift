import Foundation

/// `list_events`' `query`: words, not a phrase. A meeting matches when every word of the query
/// starts some word of its title, location or organizer, in any grammatical form: "телефония"
/// finds "…по исходящей телефонии". An abbreviation typed in capitals ("ИЗТ") must be a whole
/// word, so it does not catch longer words that merely start the same way.
struct MCPEventTextMatch {
    private struct Term {
        let text: String
        /// A whole word, not a start (an abbreviation).
        let exact: Bool
    }

    private let terms: [Term]

    /// Nil when the query has no words (empty, or only punctuation): then nothing is filtered.
    init?(_ query: String) {
        let terms = Self.rawWords(query).map { word -> Term in
            let isAbbreviation = word.count >= 2 && word.count <= 6
                && word.contains(where: \.isLetter)
                && word.allSatisfy { !$0.isLetter || $0.isUppercase }
            // Stem before folding: folding turns "й" into "и", and the endings are spelt as written.
            return isAbbreviation
                ? Term(text: Self.fold(word), exact: true)
                : Term(text: Self.fold(Self.stem(word.lowercased())), exact: false)
        }
        guard !terms.isEmpty else { return nil }
        self.terms = terms
    }

    func matches(_ fields: [String?]) -> Bool {
        let words = fields.compactMap { $0 }.flatMap(Self.rawWords).map(Self.fold)
        return terms.allSatisfy { term in
            words.contains { term.exact ? $0 == term.text : $0.hasPrefix(term.text) }
        }
    }

    // MARK: - Words

    private static func rawWords(_ text: String) -> [String] {
        text.split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    private static func fold(_ word: String) -> String {
        word.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Russian case and number endings, longest first. Enough for meeting titles: the goal is
    /// that "телефония", "телефонии" and "телефонию" meet at "телефон", not a real stemmer.
    private static let russianEndings = [
        "иями", "ями", "ами", "иях", "ием", "ией", "ого", "его", "ому", "ему", "ыми", "ими", "ых", "их",
        "ия", "ии", "ию", "ие", "ья", "ье", "ью", "ая", "яя", "ое", "ее", "ые", "ый", "ий", "ой", "ей",
        "ом", "ем", "ам", "ям", "ах", "ях", "ов", "ев", "ую", "юю",
        "а", "я", "о", "е", "ы", "и", "у", "ю", "ь", "й",
    ]
    /// Shorter words stay as typed: cutting "план" or "отдел" would match too much.
    private static let minimumStemmedLength = 6
    /// What a stem keeps at least.
    private static let minimumStem = 4

    /// The word without its ending (Russian), or without a plural `s` (English).
    static func stem(_ word: String) -> String {
        guard word.count >= minimumStemmedLength, !word.contains(where: \.isNumber) else { return word }
        if word.unicodeScalars.contains(where: { (0x0400...0x04FF).contains($0.value) }) {
            for ending in russianEndings where word.hasSuffix(ending) && word.count - ending.count >= minimumStem {
                return String(word.dropLast(ending.count))
            }
            return word
        }
        if word.hasSuffix("s"), !word.hasSuffix("ss") { return String(word.dropLast()) }
        return word
    }
}
