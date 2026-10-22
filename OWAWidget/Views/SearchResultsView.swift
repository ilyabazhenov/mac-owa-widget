import SwiftUI
import AppKit

/// Flat, day-grouped list of meetings matching the current search query.
/// Reuses `MeetingRowView` for each row and `MeetingDetailPanelView` (via `onSelect`)
/// for details, so it behaves identically to the timeline's selection flow.
struct SearchResultsView: View {
    let groups: [PopoverView.MeetingSearchPolicy.DayGroup]
    var contentHorizontalPadding: CGFloat = 12
    var selectedEventID: String? = nil
    var onSelect: (CalendarEvent) -> Void = { _ in }
    @EnvironmentObject private var localization: LocalizationService

    private var now: Date { Date() }

    var body: some View {
        if groups.isEmpty {
            emptyState
        } else {
            resultsList
        }
    }

    private var resultsList: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(groups) { group in
                    Section {
                        ForEach(group.events) { event in
                            Button { onSelect(event) } label: {
                                MeetingRowView(
                                    event: event,
                                    iconOnlyJoin: true,
                                    isPast: event.endDate < now
                                )
                                    .padding(.horizontal, contentHorizontalPadding)
                                    .padding(.vertical, 2)
                                    .background(
                                        selectedEventID == event.id
                                            ? Color.accentColor.opacity(0.12)
                                            : Color.clear
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        sectionHeader(localization.daySectionLabel(for: group.date, calendar: AppTimeZone.calendar))
                    }
                }

                scopeHint
                    .padding(.horizontal, contentHorizontalPadding)
                    .padding(.top, 10)
                    .padding(.bottom, 12)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(localization.tr("a11y.search.results"))
    }

    private var scopeHint: some View {
        HStack(spacing: 5) {
            Image(systemName: "info.circle")
                .font(.app(.micro))
            Text(localization.tr("search.scope.hint"))
                .font(.app(.caption))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.tertiary)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func sectionHeader(_ label: String) -> some View {
        Text(label)
            .font(.app(.footnote, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, contentHorizontalPadding)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.95))
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.app(.symbol))
                .foregroundStyle(.secondary)
            Text(localization.tr("search.empty.title"))
                .font(.app(.headline, weight: .medium))
            Text(localization.tr("search.empty.subtitle"))
                .font(.app(.footnote))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text(localization.tr("search.scope.hint"))
                .font(.app(.caption))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.top, 2)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
