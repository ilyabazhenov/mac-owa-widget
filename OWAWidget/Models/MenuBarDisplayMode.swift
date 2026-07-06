import Foundation

enum MenuBarDisplayMode: String, CaseIterable, Identifiable {
    case countdown
    case status
    /// Opt-in "smart status": unifies countdown + status into 3 coarse categories carried by
    /// glyph + pulse, with a compact number (duration when engaged, next meeting's time when
    /// idle). Details live in the tooltip. See `MenuBarSmartStatusFormatter`.
    case smart

    var id: String { rawValue }
}
