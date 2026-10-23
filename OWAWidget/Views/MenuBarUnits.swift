import Foundation

/// The words and unit marks of the menu bar label: "12m", "Next 7m", "Free".
///
/// The formatters stay pure and testable by taking these as a value; `LocalizationService`
/// builds the localized set, and `.english` is the default the tests are written against.
/// Each format holds one `%@` for the number (or, for `nowRemaining` / `nextIn` / `freeFor`,
/// for the already formatted duration).
struct MenuBarUnits: Equatable, Sendable {
    var minutes: String
    var hours: String
    var days: String
    var nowRemaining: String
    var nowOverlap: String
    var nextIn: String
    var free: String
    var freeFor: String

    static let english = MenuBarUnits(
        minutes: "%@m",
        hours: "%@h",
        days: "%@d",
        nowRemaining: "Now %@",
        nowOverlap: "Now x%@",
        nextIn: "Next %@",
        free: "Free",
        freeFor: "Free %@"
    )

    /// `padded` right-aligns a one-digit number in two places, so the countdown does not
    /// shift the menu bar items to its left as it ticks from 10 to 9.
    func minutes(_ value: Int, padded: Bool = false) -> String { fill(minutes, value, padded) }
    func hours(_ value: Int, padded: Bool = false) -> String { fill(hours, value, padded) }
    func days(_ value: Int, padded: Bool = false) -> String { fill(days, value, padded) }

    func fill(_ format: String, _ text: String) -> String {
        format.replacingOccurrences(of: "%@", with: text)
    }

    private func fill(_ format: String, _ value: Int, _ padded: Bool) -> String {
        fill(format, padded ? String(format: "%2d", value) : String(value))
    }
}
