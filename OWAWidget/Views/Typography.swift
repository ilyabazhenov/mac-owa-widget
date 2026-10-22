import SwiftUI

/// The app's type scale. Every text and symbol size in the interface is one of these steps, so
/// the same kind of element is the same size wherever it appears, and a change of scale is a
/// change in one place.
///
/// The sizes are fixed points rather than Dynamic Type styles: the popover is a fixed-size panel
/// laid out to the point (the timeline draws one point per minute), and macOS has no Dynamic
/// Type for text to follow anyway.
enum AppTextStyle: CaseIterable {
    /// 9 pt — dense chrome only: badges and meta inside compact timeline cards, count bubbles,
    /// glyphs on small buttons. Never for text meant to be read through.
    case micro
    /// 10 pt — secondary meta: times under a title, grid labels, tags.
    case caption
    /// 11 pt — the smallest reading size: subtitles, previews, the status line.
    case footnote
    /// 12 pt — body text and controls.
    case body
    /// 13 pt — row titles and section headers.
    case headline
    /// 15 pt — window and panel titles.
    case title
    /// 17 pt — the title of an opened message; large glyphs.
    case largeTitle
    /// 24 pt — the symbol over an empty or error state.
    case symbol

    var pointSize: CGFloat {
        switch self {
        case .micro: 9
        case .caption: 10
        case .footnote: 11
        case .body: 12
        case .headline: 13
        case .title: 15
        case .largeTitle: 17
        case .symbol: 24
        }
    }
}

extension Font {
    /// A step of the app's type scale; see `AppTextStyle`.
    static func app(_ style: AppTextStyle, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        .system(size: style.pointSize, weight: weight, design: design)
    }
}
