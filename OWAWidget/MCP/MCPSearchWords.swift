import Foundation

/// The words of a plain `search_mail` query, for telling which of them leaves no results.
///
/// Exchange returns only results that contain every word of the query (each matched by its
/// beginning and its word forms), so a long phrase often finds nothing while each word alone
/// finds plenty. A query written in KQL (quotes, `field:value`, parentheses, OR/AND/NOT) is the
/// caller's own logic and gets no per-word hint.
enum MCPSearchWords {
    /// Words checked one by one at most: each is a request to Exchange.
    static let maxChecked = 4

    private static let operators: Set<String> = ["OR", "AND", "NOT", "NEAR"]
    private static let syntax = CharacterSet(charactersIn: "\":()[]{}<>=*")

    /// The distinct words of `text` in order (case-insensitively), or `[]` when fewer than two
    /// are left or it uses search syntax. Punctuation on its own ("—", "/", "&") and one-letter
    /// words ("и", "в", "a") are not checked: each check is a request, and these say nothing.
    static func hintWords(_ text: String) -> [String] {
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.contains(where: { $0.unicodeScalars.contains(where: syntax.contains) }) else { return [] }
        let meaningful = tokens.filter { token in
            let letters = token.unicodeScalars.filter(CharacterSet.alphanumerics.contains)
            guard !letters.isEmpty else { return false }
            return !(letters.count == 1 && token.count == 1 && token.unicodeScalars.allSatisfy(CharacterSet.letters.contains))
        }
        guard !meaningful.contains(where: { operators.contains($0) || $0.hasPrefix("-") }) else { return [] }
        var seen = Set<String>()
        let words = meaningful.filter { seen.insert($0.lowercased()).inserted }
        return words.count >= 2 ? words : []
    }
}
