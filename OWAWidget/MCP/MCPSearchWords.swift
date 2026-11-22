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

    /// The distinct words of `text` in order (case-insensitively), or `[]` when it is a single
    /// word or uses search syntax.
    static func hintWords(_ text: String) -> [String] {
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard tokens.count >= 2 else { return [] }
        for token in tokens {
            if operators.contains(token) || token.unicodeScalars.contains(where: syntax.contains) || token.hasPrefix("-") {
                return []
            }
        }
        var seen = Set<String>()
        let words = tokens.filter { seen.insert($0.lowercased()).inserted }
        return words.count >= 2 ? words : []
    }
}
