import Foundation

/// Outlook's category colours: the `color` numbers of the user's category list, which are also
/// Graph's `preset0`…`preset24`.
enum OutlookCategoryColor {
    static let presets = 0...24

    static let red = 0, orange = 1, brown = 2, yellow = 3, green = 4, teal = 5, olive = 6, blue = 7
    static let purple = 8, cranberry = 9, steel = 10, darkSteel = 11, gray = 12, darkGray = 13, black = 14

    /// `presetN`, as Graph and Outlook's own clients name it.
    static func presetName(_ preset: Int) -> String { "preset\(preset)" }

    /// A guess from the name, for a category whose list is unknown: Outlook's default categories
    /// are named after their colour ("Желтая категория", "Blue category").
    static func guess(fromName name: String) -> Int? {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        let words: [([String], Int)] = [
            (["yellow", "желт", "жёлт"], yellow),
            (["orange", "оранж"], orange),
            (["red", "красн"], red),
            (["pink", "розов"], cranberry),
            (["purple", "violet", "lilac", "фиолет", "лилов"], purple),
            (["blue", "син", "голуб"], blue),
            (["green", "зелен", "зелён"], green),
            (["gray", "grey", "сер"], gray),
        ]
        return words.first { $0.0.contains(where: normalized.contains) }?.1
    }
}

extension CalendarEvent {
    /// The colour preset of one of the meeting's categories, `nil` for none. Taken from the user's
    /// category list when it is known; guessed from the name when it is not.
    func colorPreset(ofCategory name: String) -> Int? {
        guard let categoryColors else { return OutlookCategoryColor.guess(fromName: name) }
        return categoryColors[name]
    }

    /// The meeting's colour as Outlook shows it: that of its first category that has one.
    var categoryColorPreset: Int? {
        categories.lazy.compactMap(colorPreset(ofCategory:)).first
    }
}
