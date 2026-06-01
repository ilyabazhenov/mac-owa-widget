import SwiftUI

struct AllDayEventsHeaderView: View {
    let events: [CalendarEvent]
    var contentHorizontalPadding: CGFloat = 12
    var timeColumnWidth: CGFloat = 56
    var selectedEventID: String? = nil
    var onSelect: (CalendarEvent) -> Void = { _ in }

    @EnvironmentObject private var localization: LocalizationService

    private let pillSpacing: CGFloat = 4
    private let inlineThreshold = 3

    var body: some View {
        if events.isEmpty {
            EmptyView()
        } else {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "sun.max.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: timeColumnWidth, alignment: .trailing)
                    .accessibilityLabel(localization.tr("meeting.allday.icon.a11y"))

                pillsContainer
            }
            .padding(.horizontal, contentHorizontalPadding)
            .padding(.vertical, 6)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color(nsColor: .separatorColor).opacity(0.4))
                    .frame(height: 1)
                    .padding(.leading, contentHorizontalPadding + timeColumnWidth + 10)
            }
        }
    }

    @ViewBuilder
    private var pillsContainer: some View {
        if events.count <= inlineThreshold {
            HStack(spacing: pillSpacing) {
                ForEach(events) { pill(for: $0) }
                Spacer(minLength: 0)
            }
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: pillSpacing) {
                    ForEach(events) { pill(for: $0) }
                }
            }
        }
    }

    private func pill(for event: CalendarEvent) -> some View {
        let isSelected = selectedEventID == event.id
        let base = meetingAccentColor(for: event)
        return Button { onSelect(event) } label: {
            Text(event.title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(event.isEffectivelyCancelled ? .secondary : .primary)
                .strikethrough(event.isEffectivelyCancelled)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(base.opacity(isSelected ? 0.28 : 0.18))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(base.opacity(isSelected ? 0.8 : 0.32),
                                lineWidth: isSelected ? 1.2 : 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(localization.tr("meeting.allday.pill.a11y", event.title))
        .accessibilityHint(localization.tr("a11y.meeting.open.details.hint"))
    }
}
