import SwiftUI

/// One of the two day-stepping arrows in the popover's date bar.
///
/// The glyph stays small — the popover is dense — but the *target* does not. A bare `Image`
/// inside a `.plain` button is hit-testable only where the chevron's own strokes are, roughly
/// 7x11 pt, and users reported missing it on the first try.
///
/// Two things widen it. The chevron sits in a `chipWidth x chipHeight` rectangle that also
/// carries the hover shading — without that shading nothing would tell the user the target is
/// wider than the glyph. Around it, padding is folded *into* the tappable rectangle through
/// `contentShape` instead of being applied around the button, so the target runs to the popover's
/// edge, which is the cheapest place on screen to hit.
///
/// The two insets are deliberately unequal: a hair towards the window edge, the date bar's full
/// padding towards the label. Splitting it evenly would push the chevron visibly inwards, out of
/// line with the header above it.
struct DayNavArrowButton: View {
    enum Direction {
        case previous
        case next

        var systemImage: String {
            switch self {
            case .previous: return "chevron.left"
            case .next: return "chevron.right"
            }
        }
    }

    let direction: Direction
    let isEnabled: Bool
    let accessibilityLabel: String
    /// Padding towards the label, folded into the tappable rectangle.
    let innerInset: CGFloat
    let action: () -> Void

    @State private var isHovered = false

    private let chipWidth: CGFloat = 26
    private let chipHeight: CGFloat = 24
    /// Padding towards the window edge. Small on purpose: it keeps the chevron where it has
    /// always been while the target still reaches the edge.
    private let edgeInset: CGFloat = 2

    private var leadingInset: CGFloat {
        direction == .previous ? edgeInset : innerInset
    }

    private var trailingInset: CGFloat {
        direction == .previous ? innerInset : edgeInset
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: direction.systemImage)
                .font(.app(.body, weight: .semibold))
                .foregroundStyle(isEnabled ? Color.primary : Color.secondary.opacity(0.35))
                .frame(width: chipWidth, height: chipHeight)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isHovered && isEnabled ? Color.secondary.opacity(0.12) : Color.clear)
                )
                .padding(.leading, leadingInset)
                .padding(.trailing, trailingInset)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        // Stores where the pointer is, nothing else. Folding `isEnabled` in here would freeze a
        // stale answer: hover events only fire when the pointer crosses the button's edge, so an
        // arrow that re-enables under a resting cursor would never light up. The `background`
        // above already gates on `isEnabled`.
        .onHover { isHovered = $0 }
        .accessibilityLabel(accessibilityLabel)
    }
}
