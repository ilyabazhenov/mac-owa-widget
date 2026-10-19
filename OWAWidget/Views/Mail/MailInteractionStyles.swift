import SwiftUI

/// Pointer feedback shared by mail's rows and small buttons: a light fill under the pointer and a
/// darker one while pressed. `.plain` buttons and tap gestures give neither, so a click on a row
/// or an icon looked like nothing happened until the server answered.
enum MailHover {
    static let animation = Animation.easeOut(duration: 0.12)

    static func fill(hovered: Bool, pressed: Bool) -> Color {
        if pressed { return Color.primary.opacity(0.12) }
        return hovered ? Color.primary.opacity(0.06) : .clear
    }
}

/// A clickable row or chip: the fill sits behind the label's own background (a selected row
/// keeps its accent fill on top of it).
struct MailRowButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = 6

    func makeBody(configuration: Configuration) -> some View {
        RowBody(configuration: configuration, cornerRadius: cornerRadius)
    }

    private struct RowBody: View {
        let configuration: Configuration
        let cornerRadius: CGFloat
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(MailHover.fill(hovered: isHovered && isEnabled, pressed: configuration.isPressed && isEnabled))
                )
                .contentShape(Rectangle())
                .onHover { isHovered = $0 }
                .animation(MailHover.animation, value: isHovered)
        }
    }
}

/// A small icon (or icon and text) button: a rounded square appears under the pointer, as on
/// toolbar buttons. Replaces `.borderless` / `.plain`, which show nothing on hover.
struct MailIconButtonStyle: ButtonStyle {
    var horizontalPadding: CGFloat = 5
    var verticalPadding: CGFloat = 3

    func makeBody(configuration: Configuration) -> some View {
        IconBody(configuration: configuration, horizontalPadding: horizontalPadding, verticalPadding: verticalPadding)
    }

    private struct IconBody: View {
        let configuration: Configuration
        let horizontalPadding: CGFloat
        let verticalPadding: CGFloat
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, verticalPadding)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(MailHover.fill(hovered: isHovered && isEnabled, pressed: configuration.isPressed && isEnabled))
                )
                .contentShape(Rectangle())
                .opacity(isEnabled ? 1 : 0.4)
                .onHover { isHovered = $0 }
                .animation(MailHover.animation, value: isHovered)
        }
    }
}

extension ButtonStyle where Self == MailIconButtonStyle {
    static var mailIcon: MailIconButtonStyle { MailIconButtonStyle() }
    /// For the tiny "×" of a chip.
    static var mailIconCompact: MailIconButtonStyle { MailIconButtonStyle(horizontalPadding: 3, verticalPadding: 2) }
}

extension ButtonStyle where Self == MailRowButtonStyle {
    static var mailRow: MailRowButtonStyle { MailRowButtonStyle() }
    static func mailRow(cornerRadius: CGFloat) -> MailRowButtonStyle { MailRowButtonStyle(cornerRadius: cornerRadius) }
}

/// The hover fill for views that are not buttons: rows opened by a tap gesture (they need the
/// click's modifier keys) and menus, whose style a `ButtonStyle` does not reach.
private struct MailHoverHighlight: ViewModifier {
    let cornerRadius: CGFloat
    let isEnabled: Bool
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: cornerRadius).fill(MailHover.fill(hovered: isHovered && isEnabled, pressed: false)))
            .onHover { isHovered = $0 }
            .animation(MailHover.animation, value: isHovered)
    }
}

extension View {
    /// A light fill while the pointer is over the view; off while `enabled` is false (a selected
    /// row already shows its own fill).
    func mailHover(cornerRadius: CGFloat = 6, enabled: Bool = true) -> some View {
        modifier(MailHoverHighlight(cornerRadius: cornerRadius, isEnabled: enabled))
    }

    /// An icon menu drawn as `MailIconButtonStyle`: the same size, padding and hover as the
    /// buttons beside it. A `.borderlessButton` menu draws its symbol larger, adds a chevron and
    /// pads itself, so it stood out of a row of icon buttons.
    func mailIconMenu() -> some View {
        menuStyle(.button)
            .buttonStyle(.mailIcon)
            .menuIndicator(.hidden)
            .fixedSize()
    }
}

/// An icon of a row of icon buttons: one size, and one width so the gaps between them are even
/// (SF Symbols differ in width: an envelope is half as wide again as a flag).
struct MailActionIcon: View {
    let systemName: String

    init(_ systemName: String) { self.systemName = systemName }

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 13))
            .frame(width: 18, height: 16)
    }
}
