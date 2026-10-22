import SwiftUI

/// One colleague: avatar, name, current status, and a join button when a room link is known.
///
/// Compact on purpose (30 pt tall): the section sits under the meeting list and every point it
/// takes is a point the timeline loses.
struct ColleagueRowView: View {
    let colleague: WatchedColleague
    let status: ColleagueStatus
    let isStale: Bool
    let now: Date
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onJoin: (URL) -> Void
    let onEdit: () -> Void
    /// -1 moves the row one place up, +1 one place down.
    let onMove: (Int) -> Void
    /// Set while this row is the one being dragged.
    let isDragging: Bool
    /// Edge to draw the insertion line on, or `nil` when this row is not the drop target.
    let dropEdge: VerticalEdge?
    let onRemove: () -> Void

    @EnvironmentObject private var localization: LocalizationService
    @State private var isHovered = false

    private var roomURL: URL? { ColleagueRoomLink.normalized(colleague.roomURL) }

    private var statusText: String {
        ColleagueStatusFormatter.text(for: status, now: now, localization: localization)
    }

    var body: some View {
        HStack(spacing: 8) {
            InitialsAvatar(name: colleague.displayName, size: 20)

            Text(ColleagueNameFormatter.abbreviated(colleague.displayName))
                .font(.app(.body, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(isStale ? Color.primary.opacity(0.75) : Color.primary)
                .help(colleague.displayName)

            Spacer(minLength: 6)

            statusDot

            Text(statusText)
                .font(.app(.footnote))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundStyle(isStale ? Color.secondary.opacity(0.75) : Color.secondary)

            // The join icon keeps its slot whether or not it is drawn, so names and statuses line
            // up down the section. Editing and removing live in the context menu only: a visible
            // menu button cost a second column on every row for an action used once per colleague.
            Group {
                if let roomURL {
                    Button { onJoin(roomURL) } label: {
                        Image(systemName: "arrow.right.circle.fill")
                            .font(.app(.title))
                            .foregroundStyle(joinForeground)
                    }
                    .buttonStyle(.plain)
                    .help(localization.tr("colleagues.menu.join"))
                    .accessibilityLabel(localization.tr("a11y.colleagues.join", colleague.displayName))
                }
            }
            .frame(width: 16)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 14)
        .background(rowBackground)
        .overlay(alignment: dropEdge == .bottom ? .bottom : .top) {
            // Where the dragged row will land. Drawn on top so it never nudges the layout.
            if dropEdge != nil {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(height: 2)
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .contextMenu { menuContent }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(colleague.displayName), \(statusText)")
    }

    @ViewBuilder
    private var menuContent: some View {
        if let roomURL {
            Button(localization.tr("colleagues.menu.join")) { onJoin(roomURL) }
        }
        Button(localization.tr("colleagues.menu.edit")) { onEdit() }
        Divider()
        Button(localization.tr("colleagues.menu.moveUp")) { onMove(-1) }
            .disabled(!canMoveUp)
        Button(localization.tr("colleagues.menu.moveDown")) { onMove(1) }
            .disabled(!canMoveDown)
        Divider()
        Button(localization.tr("colleagues.menu.remove")) { onRemove() }
    }

    private var rowBackground: Color {
        if isDragging { return Color.accentColor.opacity(0.10) }
        return isHovered ? Color.secondary.opacity(0.06) : Color.clear
    }

    /// Hollow while the data is stale: the timetable still holds, but it may have been rewritten
    /// since the last successful fetch.
    private var statusDot: some View {
        let color = ColleaguePresenceStyle.color(for: status.presence)
        return Group {
            if isStale {
                Circle().strokeBorder(color, lineWidth: 1.5)
            } else {
                Circle().fill(color)
            }
        }
        .frame(width: 7, height: 7)
    }

    private var joinForeground: Color {
        ColleaguePresenceStyle.joinIsProminent(for: status.presence)
            ? Color.accentColor
            : Color.secondary.opacity(0.7)
    }
}
