import Foundation

/// Matches user-typed name tokens against GAL `displayName` / `email` when scripts differ
/// (e.g. user types Cyrillic `"иван"` while directory returns Latin `"Ivan Kovalenko"`).
enum OWAPersonSearchTokenMatch {
    /// Lowercased strings plus optional Latin transliteration (ICU `StringTransform.toLatin`).
    static func normalizedForms(_ s: String) -> Set<String> {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let lower = trimmed.lowercased()
        var forms: Set<String> = [lower]
        if let latin = lower.applyingTransform(StringTransform.toLatin, reverse: false), !latin.isEmpty {
            forms.insert(latin.lowercased())
        }
        return forms
    }

    static func personContainsToken(displayName: String, email: String, token: String) -> Bool {
        let tokenForms = normalizedForms(token)
        let haystackForms = normalizedForms(displayName).union(normalizedForms(email))
        guard !tokenForms.isEmpty, !haystackForms.isEmpty else { return false }
        for h in haystackForms {
            for t in tokenForms where !t.isEmpty {
                if h.contains(t) { return true }
            }
        }
        return false
    }
}
