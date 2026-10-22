import SwiftUI

/// The expanded half of the colleagues section, sitting under the meeting list.
///
/// Its height is computed from the rows it actually shows and capped at the row limit, so the
/// block costs the timeline the same whether the user watches four colleagues or thirty. A
/// `ScrollView` is greedy in its scroll axis: giving one a `maxHeight` makes it take the whole
/// allowance rather than hug its content, which is why every height here is measured, not maximal.
struct ColleaguesPanelView: View {
    @ObservedObject var model: ColleaguesSectionModel
    let horizontalPadding: CGFloat
    let onJoin: (URL) -> Void

    @EnvironmentObject private var presence: ColleaguePresenceService
    @EnvironmentObject private var service: CalendarService
    @EnvironmentObject private var localization: LocalizationService

    @State private var searchQuery = ""
    @State private var searchResults: [ResolvedAttendee] = []
    @State private var isSearching = false
    /// Reordering is done by hand rather than with `draggable`/`dropDestination`: the popover is a
    /// non-activating panel, and the AppKit drag session never reaches it — the row lifts, and the
    /// drop is silently dropped. A plain drag gesture over rows of known height needs no session.
    @State private var draggingID: String?
    @State private var draggingIndex: Int?
    @State private var dragTranslation: CGFloat = 0
    @FocusState private var searchFieldFocused: Bool

    /// Must match ``ColleagueRowView``: 20-point avatar plus 5 points of padding either side.
    private let rowHeight: CGFloat = 30
    private let listVerticalPadding: CGFloat = 4

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            switch model.mode {
            case .list:
                listContent(now: context.date)
            case .search:
                searchContent
            case .edit(let colleague):
                ColleagueEditCardView(
                    colleague: colleague,
                    onSave: { updated in
                        presence.update(updated)
                        model.backToList()
                    },
                    onCancel: { model.backToList() },
                    onRemove: {
                        presence.remove(colleague)
                        model.backToList()
                    }
                )
            }
        }
    }

    // MARK: - List

    @ViewBuilder
    private func listContent(now: Date) -> some View {
        if presence.colleagues.isEmpty {
            emptyState
        } else {
            // Everyone is on the list, always. What the row limit buys is a ceiling on the
            // block's height: past it the list scrolls instead of growing.
            let all = presence.colleagues
            let limit = max(1, service.colleaguesRowLimit)
            let contentHeight = CGFloat(all.count) * rowHeight + listVerticalPadding
            let cappedHeight = CGFloat(limit) * rowHeight + listVerticalPadding

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(all.enumerated()), id: \.element.id) { index, colleague in
                        ColleagueRowView(
                            colleague: colleague,
                            status: presence.status(for: colleague, now: now),
                            isStale: isStale,
                            now: now,
                            canMoveUp: presence.canMove(colleague, by: -1),
                            canMoveDown: presence.canMove(colleague, by: 1),
                            onJoin: onJoin,
                            onEdit: { model.edit(colleague) },
                            onMove: { offset in presence.move(colleague, by: offset) },
                            isDragging: draggingID == colleague.id,
                            dropEdge: dropEdge(for: index),
                            onRemove: { presence.remove(colleague) }
                        )
                        .offset(y: draggingID == colleague.id ? dragTranslation : 0)
                        .zIndex(draggingID == colleague.id ? 1 : 0)
                        .gesture(reorderGesture(colleague: colleague, index: index, count: all.count))
                    }
                }
                .padding(.vertical, listVerticalPadding / 2)
            }
            .frame(height: min(contentHeight, cappedHeight))
            .scrollIndicators(.automatic)
            .scrollDisabled(contentHeight <= cappedHeight)
        }
    }

    // MARK: - Reordering

    private func reorderGesture(colleague: WatchedColleague, index: Int, count: Int) -> some Gesture {
        // A press before the drag keeps the gesture out of the way of the scroll view and of the
        // join button, which sits inside the same row.
        LongPressGesture(minimumDuration: 0.18)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
            .onChanged { value in
                guard case .second(true, let drag?) = value else { return }
                draggingID = colleague.id
                draggingIndex = index
                dragTranslation = drag.translation.height
            }
            .onEnded { _ in
                commitReorder(count: count)
            }
    }

    /// Rows are a fixed height, so the slot under the cursor is arithmetic, not hit-testing.
    private var dropTargetIndex: Int? {
        guard draggingID != nil, let from = draggingIndex else { return nil }
        let shift = Int((dragTranslation / rowHeight).rounded())
        guard shift != 0 else { return nil }
        return from + shift
    }

    private func dropEdge(for index: Int) -> VerticalEdge? {
        guard let target = dropTargetIndex, let from = draggingIndex, target == index else { return nil }
        return target > from ? .bottom : .top
    }

    private func commitReorder(count: Int) {
        defer {
            draggingID = nil
            draggingIndex = nil
            dragTranslation = 0
        }
        guard let id = draggingID, let from = draggingIndex, let raw = dropTargetIndex else { return }
        let target = max(0, min(count - 1, raw))
        guard target != from else { return }
        presence.reorder(draggedID: id, toIndex: target)
    }

    private var isStale: Bool {
        if case .stale = presence.freshness { return true }
        return false
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text(localization.tr("colleagues.empty.title"))
                .font(.app(.footnote))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                model.openSearch()
            } label: {
                Text(localization.tr("colleagues.empty.action"))
                    .font(.app(.footnote, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.15))
                    .foregroundStyle(Color.accentColor)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, horizontalPadding + 12)
        .padding(.vertical, 12)
    }

    // MARK: - Search

    private var searchContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.app(.footnote))
                    .foregroundStyle(.secondary)

                TextField(localization.tr("colleagues.search.placeholder"), text: $searchQuery)
                    .textFieldStyle(.plain)
                    .font(.app(.body))
                    .focused($searchFieldFocused)

                if isSearching {
                    ProgressView().scaleEffect(0.4).frame(width: 12, height: 12)
                }

                Button {
                    searchQuery = ""
                    searchResults = []
                    model.backToList()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.app(.footnote))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(localization.tr("colleagues.edit.cancel"))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
            .padding(.horizontal, horizontalPadding)
            .padding(.top, 8)
            .padding(.bottom, 6)

            if !searchResults.isEmpty {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(searchResults) { attendee in
                            searchResultRow(attendee)
                        }
                    }
                }
                .frame(height: min(CGFloat(searchResults.count) * rowHeight, CGFloat(4) * rowHeight))
                .scrollIndicators(.never)
                .padding(.bottom, 4)
            } else if !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty, !isSearching {
                Text(localization.tr("colleagues.search.empty"))
                    .font(.app(.footnote))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, horizontalPadding)
                    .padding(.bottom, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear { searchFieldFocused = true }
        .task(id: searchQuery) { await runSearch() }
    }

    private func searchResultRow(_ attendee: ResolvedAttendee) -> some View {
        let alreadyAdded = presence.contains(attendee)
        return Button {
            guard !alreadyAdded else { return }
            presence.add(attendee)
            searchQuery = ""
            searchResults = []
            if let stored = presence.colleagues.first(where: { $0.id == attendee.email.lowercased() }) {
                model.edit(stored)
            } else {
                model.backToList()
            }
        } label: {
            HStack(spacing: 8) {
                InitialsAvatar(name: attendee.displayName, size: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(attendee.displayName)
                        .font(.app(.body, weight: .medium))
                        .lineLimit(1)
                    Text(attendee.jobTitle ?? attendee.email)
                        .font(.app(.caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 6)
                if alreadyAdded {
                    Text(localization.tr("colleagues.search.already"))
                        .font(.app(.caption))
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: "plus")
                        .font(.app(.footnote, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(alreadyAdded)
    }

    private func runSearch() async {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else {
            searchResults = []
            isSearching = false
            return
        }
        // Typing is faster than FindPeople: wait out the burst before spending a request.
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled else { return }

        isSearching = true
        defer { isSearching = false }
        do {
            let people = try await presence.searchPeople(query: query)
            guard !Task.isCancelled else { return }
            searchResults = Array(people.prefix(6))
        } catch {
            guard !Task.isCancelled else { return }
            searchResults = []
        }
    }
}
