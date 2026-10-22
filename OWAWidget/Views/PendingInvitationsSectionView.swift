import SwiftUI

/// Collapsible "new invitations" strip above the day timeline.
///
/// The invitation panel can be closed and forgotten; this strip cannot. It stays until each
/// invitation is answered or hidden, which is what makes a missed panel recoverable. Collapsed by
/// default, and scrolls past a few rows, so it never eats the timeline.
struct PendingInvitationsSectionView: View {
    let groups: [MeetingInvitationGroup]
    let horizontalPadding: CGFloat
    let onSelect: (CalendarEvent) -> Void
    let onDismiss: (MeetingInvitationGroup) -> Void

    private static let maxListHeight: CGFloat = 140

    @EnvironmentObject private var localization: LocalizationService
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "envelope.badge")
                        .font(.app(.footnote, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                    Text(localization.tr("invitations.pending.title"))
                        .font(.app(.body, weight: .semibold))
                    Text("\(groups.count)")
                        .font(.app(.caption, weight: .semibold))
                        .monospacedDigit()
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                        .foregroundStyle(Color.accentColor)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.app(.micro, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(localization.tr("invitations.pending.a11y", groups.count))

            if isExpanded {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(groups) { group in
                            row(group)
                        }
                    }
                }
                .frame(maxHeight: Self.maxListHeight)
                .fixedSize(horizontal: false, vertical: groups.count <= 5)
                .padding(.bottom, 6)
            }
        }
    }

    private func row(_ group: MeetingInvitationGroup) -> some View {
        HStack(spacing: 0) {
            selectButton(group)
            Button { onDismiss(group) } label: {
                Image(systemName: "xmark")
                    .font(.app(.micro, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(localization.tr("invitations.action.hide"))
            .accessibilityLabel(localization.tr("invitations.action.hide"))
            .padding(.trailing, horizontalPadding - 6)
        }
    }

    private func selectButton(_ group: MeetingInvitationGroup) -> some View {
        let event = group.representative
        return Button { onSelect(event) } label: {
            HStack(spacing: 8) {
                Text(whenLabel(event))
                    .font(.app(.footnote, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: 118, alignment: .leading)
                Text(event.title)
                    .font(.app(.footnote))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if group.occurrenceCount > 1 {
                    Text("×\(group.occurrenceCount)")
                        .font(.app(.caption, weight: .medium))
                        .foregroundStyle(.secondary)
                        .help(localization.tr("invitations.pending.series.help", group.occurrenceCount))
                }
            }
            .padding(.leading, horizontalPadding)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(event.organizer.map { localization.tr("invitations.pending.organizer", $0) } ?? event.title)
    }

    /// Short enough for a fixed column.
    private func whenLabel(_ event: CalendarEvent) -> String {
        InvitationLabel.when(event, localization: localization)
    }
}
