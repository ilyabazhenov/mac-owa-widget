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
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                    Text(localization.tr("invitations.pending.title"))
                        .font(.system(size: 12, weight: .semibold))
                    Text("\(groups.count)")
                        .font(.system(size: 10, weight: .semibold))
                        .monospacedDigit()
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                        .foregroundStyle(Color.accentColor)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
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
                    .font(.system(size: 8, weight: .semibold))
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
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: 118, alignment: .leading)
                Text(event.title)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if group.occurrenceCount > 1 {
                    Text("×\(group.occurrenceCount)")
                        .font(.system(size: 10, weight: .medium))
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

    /// "Today, 14:00", "Tomorrow, 9:30", "Fri, 26 Sep, 11:00" — short enough for a fixed column.
    private func whenLabel(_ event: CalendarEvent) -> String {
        let calendar = AppTimeZone.calendar
        let day: String
        if calendar.isDateInToday(event.startDate) {
            day = localization.tr("date.today")
        } else if calendar.isDateInTomorrow(event.startDate) {
            day = localization.tr("date.tomorrow")
        } else {
            let formatter = DateFormatter()
            formatter.locale = localization.locale
            formatter.timeZone = AppTimeZone.zone
            formatter.setLocalizedDateFormatFromTemplate("EEEdMMM")
            day = formatter.string(from: event.startDate)
        }
        guard !event.isAllDay else { return day }
        return "\(day), \(localization.shortTime(event.startDate))"
    }
}
