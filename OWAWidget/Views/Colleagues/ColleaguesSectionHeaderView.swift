import SwiftUI

/// The always-visible half of the colleagues section: one 32-point row above the footer.
///
/// Closed, it still answers the question the section exists for — the avatars are the people who
/// are free right now, and clicking one goes straight into their room.
struct ColleaguesSectionHeaderView: View {
    @ObservedObject var model: ColleaguesSectionModel
    let horizontalPadding: CGFloat
    let onJoin: (URL) -> Void

    @EnvironmentObject private var presence: ColleaguePresenceService
    @EnvironmentObject private var service: CalendarService
    @EnvironmentObject private var localization: LocalizationService

    @State private var isHovered = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            HStack(spacing: 7) {
                Image(systemName: "person.2")
                    .font(.app(.footnote))
                    .foregroundStyle(.secondary)

                Text(localization.tr("colleagues.section.title"))
                    .font(.app(.body, weight: .semibold))

                Spacer(minLength: 6)

                trailingSummary(now: context.date)

                if presence.isRefreshing {
                    ProgressView()
                        .scaleEffect(0.45)
                        .frame(width: 12, height: 12)
                }

                Button {
                    model.openSearch()
                } label: {
                    Image(systemName: "plus")
                        .font(.app(.footnote, weight: .medium))
                }
                .buttonStyle(.plain)
                .help(localization.tr("colleagues.add"))
                .accessibilityLabel(localization.tr("colleagues.add"))

                Button(action: model.toggleExpansion) {
                    Image(systemName: model.isExpanded ? "chevron.up" : "chevron.down")
                        .font(.app(.caption, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(localization.tr(model.isExpanded ? "colleagues.collapse" : "colleagues.expand"))
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, 7)
            // The whole header is the target, not just the chevron. The plus, the chevron and the
            // avatars keep their own taps — the innermost gesture wins.
            .background(isHovered ? Color.secondary.opacity(0.06) : Color.clear)
            .contentShape(Rectangle())
            .onTapGesture { model.toggleExpansion() }
            .onHover { isHovered = $0 }
        }
    }

    /// Expanded, the header only has to count. Closed, it carries the free colleagues themselves.
    @ViewBuilder
    private func trailingSummary(now: Date) -> some View {
        switch presence.freshness {
        case .stale(let since):
            badge(
                text: localization.tr("colleagues.offline.badge", localization.shortTime(since)),
                color: .secondary,
                background: Color.secondary.opacity(0.12)
            )
        case .fresh where !presence.colleagues.isEmpty:
            if model.isExpanded {
                counterBadge(now: now)
            } else {
                avatarStrip(now: now)
            }
        default:
            EmptyView()
        }
    }

    private func counterBadge(now: Date) -> some View {
        badge(
            text: localization.tr("colleagues.counter", presence.freeCount(now: now), presence.colleagues.count),
            color: ColleaguePresenceStyle.color(for: .free),
            background: ColleaguePresenceStyle.color(for: .free).opacity(0.18)
        )
    }

    /// Everyone, in the user's own order, each ringed in their status colour. Free faces stay at
    /// full strength and the rest step back, so "who can I call right now" is still one glance —
    /// but the strip no longer hides people who are simply busy.
    @ViewBuilder
    private func avatarStrip(now: Date) -> some View {
        let all = presence.colleagues

        if all.isEmpty {
            EmptyView()
        } else {
            let visible = ColleagueAvatarStripLayout.visibleCount(
                totalCount: all.count,
                popoverWidth: service.popoverSize.width
            )
            HStack(spacing: ColleagueAvatarStripLayout.spacing) {
                ForEach(all.prefix(visible)) { colleague in
                    let status = presence.status(for: colleague, now: now)
                    Button {
                        // Joining is offered from here only when the person is actually
                        // available; for anyone else the strip just opens the list.
                        if let url = ColleagueRoomLink.normalized(colleague.roomURL),
                           ColleaguePresenceStyle.joinIsProminent(for: status.presence) {
                            onJoin(url)
                        } else {
                            model.isExpanded = true
                        }
                    } label: {
                        InitialsAvatar(name: colleague.displayName, size: ColleagueAvatarStripLayout.avatarSize)
                            .overlay(
                                Circle().strokeBorder(
                                    ColleaguePresenceStyle.color(for: status.presence),
                                    lineWidth: 1.5
                                )
                            )
                            .opacity(status.presence == .free ? 1 : 0.55)
                    }
                    .buttonStyle(.plain)
                    .help(help(for: colleague, now: now))
                    .accessibilityLabel(help(for: colleague, now: now))
                }

                if all.count > visible {
                    Text("+\(all.count - visible)")
                        .font(.app(.caption, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func help(for colleague: WatchedColleague, now: Date) -> String {
        let status = ColleagueStatusFormatter.text(
            for: presence.status(for: colleague, now: now),
            now: now,
            localization: localization
        )
        return "\(colleague.displayName) · \(status)"
    }

    private func badge(text: String, color: Color, background: Color) -> some View {
        Text(text)
            .font(.app(.caption, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
