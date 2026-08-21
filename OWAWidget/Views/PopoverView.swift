import SwiftUI
import AppKit

struct PopoverView: View {
    @EnvironmentObject var service: CalendarService
    @EnvironmentObject private var localization: LocalizationService
    @EnvironmentObject private var updateCheck: UpdateCheckService
    @Environment(\.openWindow) private var openWindow
    private var popoverSize: PopoverSize { service.popoverSize }
    private let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    private let appBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    private var fullVersion: String { "\(appVersion).\(appBuild)" }
    let contentHorizontalPadding: CGFloat = 12
    @State private var selectedDayOffset: Int = 0
    @State private var selectedEvent: CalendarEvent? = nil
    @State private var searchQuery: String = ""
    @State private var isSearchBarPresented: Bool = false
    @FocusState private var isSearchFieldFocused: Bool
    private let minDayOffset = -7
    private let maxDayOffset = 30

    private var isSearching: Bool {
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    enum DateNavBarPolicy {
        static func shouldShowJumpToToday(selectedDayOffset: Int) -> Bool {
            selectedDayOffset != 0
        }

        static func canGoToPreviousDay(selectedDayOffset: Int, minDayOffset: Int) -> Bool {
            selectedDayOffset > minDayOffset
        }

        static func canGoToNextDay(selectedDayOffset: Int, maxDayOffset: Int) -> Bool {
            selectedDayOffset < maxDayOffset
        }
    }

    enum MeetingDetailStatePolicy {
        static func selectedEventAfterPopoverDisappear(_ currentSelection: CalendarEvent?) -> CalendarEvent? {
            nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if isSearchBarPresented {
                Divider()
                MeetingSearchField(
                    text: $searchQuery,
                    isFocused: $isSearchFieldFocused,
                    placeholder: localization.tr("search.placeholder"),
                    onClear: { searchQuery = "" },
                    onCancel: { closeSearch() }
                )
                .padding(.horizontal, contentHorizontalPadding)
                .padding(.vertical, 8)
            }
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: CGFloat(popoverSize.width), height: CGFloat(popoverSize.height))
        .background(Color(nsColor: .windowBackgroundColor))
        .background {
            PopoverWindowRegistrar()
                .frame(width: 0, height: 0)
        }
        .onEscapeKey(perform: handleEscape)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(localization.tr("app.name"))
        .onDisappear {
            resetMeetingDetailState()
            searchQuery = ""
            isSearchBarPresented = false
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text(localization.tr("app.name"))
                .font(.system(size: 13, weight: .semibold))

            Spacer()

            Button { toggleSearch() } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundStyle(isSearchBarPresented ? Color.accentColor : .primary)
            }
            .buttonStyle(.plain)
            .help(localization.tr("popover.search"))
            .accessibilityLabel(localization.tr("popover.search"))

            if service.syncStatus.isSyncing {
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 16, height: 16)
                    .accessibilityLabel(localization.tr("sync.status.syncing"))
            } else {
                Button {
                    service.syncNow()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13))
                }
                .buttonStyle(.plain)
                .help(localization.tr("popover.sync.now"))
                .accessibilityLabel(localization.tr("popover.sync.now"))
            }

            if service.supportsMeetingCreation {
                Button { openCreateMeeting() } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 13))
                }
                .buttonStyle(.plain)
                .help(localization.tr("popover.new.meeting"))
                .accessibilityLabel(localization.tr("popover.new.meeting"))
            }

            Button { openSettings() } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .help(localization.tr("popover.settings"))
            .accessibilityLabel(localization.tr("popover.settings"))

            Button { quitApp() } label: {
                Image(systemName: "power")
                    .font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .help(localization.tr("popover.quit"))
            .accessibilityLabel(localization.tr("popover.quit"))
        }
        .padding(.horizontal, contentHorizontalPadding)
        .padding(.vertical, 11)
        .accessibilitySortPriority(selectedEvent == nil ? 1 : 0)
    }

    private var footerEngagementIndicator: some View {
        let snapshot = service.engagementSnapshot
        let percent = Int(snapshot.conversionRate * 100)
        return HStack(spacing: 4) {
            CompactCircularProgress(
                progress: snapshot.conversionRate,
                title: nil,
                lineWidth: 2
            )
            Text("\(percent)%")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .help(localization.effectiveLanguageCode == "ru" ? "Доля подключений: \(snapshot.joinedViaWidget)/\(snapshot.eligibleMeetings)" : "Join rate: \(snapshot.joinedViaWidget)/\(snapshot.eligibleMeetings)")
    }

    /// Quick popover-size switcher. Applies immediately (unlike the Settings picker,
    /// which is gated behind Save), writing straight through to the shared service.
    private var popoverSizeMenu: some View {
        Menu {
            Picker(localization.tr("preferences.popover.size"), selection: popoverSizeSelection) {
                ForEach(PopoverSize.Preset.allCases) { preset in
                    Text(localization.tr(preset.localizationKey)).tag(preset)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 10))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(localization.tr("preferences.popover.size"))
        .accessibilityLabel(localization.tr("preferences.popover.size"))
    }

    private var popoverSizeSelection: Binding<PopoverSize.Preset> {
        Binding(
            get: { service.popoverSizePreset },
            set: { service.popoverSizePreset = $0 }
        )
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        Group {
            if service.accounts.isEmpty {
                // An unreadable store is not an empty one, and must never offer "add an account":
                // that would persist a fresh list over the accounts still sitting on disk.
                if service.accountStoreUnreadable {
                    unreadableAccountStoreState
                } else {
                    noAccountState
                }
            } else if SyncPresentationPolicy.shouldShowErrorState(
                syncStatus: service.syncStatus,
                eventsCount: service.events.count
            ) {
                errorState
            } else {
                dayTimelineContent
            }
        }
    }

    private var dayTimelineContent: some View {
        ZStack(alignment: .bottom) {
            Group {
                if isSearching {
                    SearchResultsView(
                        groups: searchResultGroups,
                        contentHorizontalPadding: contentHorizontalPadding,
                        selectedEventID: selectedEvent?.id,
                        onSelect: selectEvent
                    )
                } else {
                    VStack(spacing: 0) {
                        dateNavBar
                        Divider()
                        UpdateAvailableBannerView(
                            updateCheck: updateCheck,
                            horizontalPadding: contentHorizontalPadding
                        )
                        if updateCheck.availableUpdate != nil {
                            Divider()
                        }
                        if selectedDayOffset == 0 && !nextEvents.isEmpty {
                            NextMeetingBannerView(
                                events: nextEvents,
                                horizontalPadding: contentHorizontalPadding,
                                onSelect: selectEvent
                            )
                            Divider().padding(.top, 8)
                        }
                        MeetingListView(
                            sections: eventSections,
                            contentHorizontalPadding: contentHorizontalPadding,
                            selectedEventID: selectedEvent?.id,
                            onSelect: selectEvent
                        )
                    }
                }
            }
            .accessibilityHidden(selectedEvent != nil)
            .overlay {
                if selectedEvent != nil {
                    // The dimmed area doubles as the dismiss target: clicking beside the card
                    // closes it, the way a sheet behaves. It also stops a click from landing on
                    // the timeline underneath and silently switching meetings.
                    Color(nsColor: .windowBackgroundColor)
                        .opacity(0.26)
                        .contentShape(Rectangle())
                        .onTapGesture { closeMeetingDetail() }
                        .transition(.opacity)
                        .accessibilityHidden(true)
                }
            }

            if let selectedEvent {
                MeetingDetailPanelView(event: selectedEvent) {
                    closeMeetingDetail()
                }
                .padding(.horizontal, contentHorizontalPadding)
                .padding(.bottom, 8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(1)
                .accessibilityAddTraits(.isModal)
                .accessibilitySortPriority(100)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: selectedEvent?.id)
    }

    private var dateNavBar: some View {
        HStack {
            Button {
                if DateNavBarPolicy.canGoToPreviousDay(selectedDayOffset: selectedDayOffset, minDayOffset: minDayOffset) {
                    selectedDayOffset -= 1
                    resetMeetingDetailState()
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .disabled(!DateNavBarPolicy.canGoToPreviousDay(selectedDayOffset: selectedDayOffset, minDayOffset: minDayOffset))
            .accessibilityLabel(localization.tr("a11y.nav.previous.day"))

            Spacer()

            HStack(spacing: 6) {
                Text(localization.daySectionLabel(for: selectedDate, calendar: AppTimeZone.calendar))
                    .font(.system(size: 12, weight: .semibold))
                TimeZoneBadge()
            }

            Spacer()

            if DateNavBarPolicy.shouldShowJumpToToday(selectedDayOffset: selectedDayOffset) {
                Button {
                    selectedDayOffset = 0
                    resetMeetingDetailState()
                } label: {
                    let icon = selectedDayOffset < 0 ? "arrow.uturn.forward.circle" : "arrow.uturn.backward.circle"
                    Label(localization.tr("popover.nav.today"), systemImage: icon)
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .padding(.trailing, 2)
                .accessibilityLabel(localization.tr("a11y.nav.today"))
            }

            Button {
                if DateNavBarPolicy.canGoToNextDay(selectedDayOffset: selectedDayOffset, maxDayOffset: maxDayOffset) {
                    selectedDayOffset += 1
                    resetMeetingDetailState()
                }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .disabled(!DateNavBarPolicy.canGoToNextDay(selectedDayOffset: selectedDayOffset, maxDayOffset: maxDayOffset))
            .accessibilityLabel(localization.tr("a11y.nav.next.day"))
        }
        .padding(.horizontal, contentHorizontalPadding)
        .padding(.vertical, 6)
        .accessibilitySortPriority(selectedEvent == nil ? 10 : 0)
    }

    // MARK: - Footer

    private var footer: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack(spacing: 8) {
                Text(localization.syncStatusText(service.syncStatus, relativeTo: context.date))
                    .lineLimit(1)

                if service.syncStatus.isOfflineCached {
                    Image(systemName: "wifi.slash")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                }

                // Inline retry next to the status, so the user doesn't have to find the
                // toolbar refresh. For an auth block, route through the breaker-lifting retry
                // (a plain sync would be skipped); otherwise a normal manual sync.
                if service.syncStatus.isAuthenticationRequired || service.syncStatus.isOfflineCached {
                    Button(localization.tr("popover.retry")) {
                        if service.syncStatus.isAuthenticationRequired {
                            service.retryAfterAuthBlock()
                        } else {
                            service.syncNow()
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .help(service.syncStatus.isAuthenticationRequired
                        ? localization.tr("popover.retry.help")
                        : localization.tr("popover.sync.now"))
                }

                Spacer(minLength: 8)
                footerEngagementIndicator

                popoverSizeMenu

                Text("v\(fullVersion)")
                    .lineLimit(1)
            }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .padding(.horizontal, contentHorizontalPadding)
                .padding(.vertical, 7)
        }
    }

    private func openCreateMeeting() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "create-meeting")
    }

    private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "settings")
    }

    private func quitApp() {
        NSApp.terminate(nil)
    }

    private func selectEvent(_ event: CalendarEvent) {
        withAnimation(.easeInOut(duration: 0.18)) {
            selectedEvent = event
        }
    }

    private func resetMeetingDetailState() {
        selectedEvent = MeetingDetailStatePolicy.selectedEventAfterPopoverDisappear(selectedEvent)
    }

    /// Esc unwinds the popover one layer at a time — card, then search, then the popover itself —
    /// so a single monitor owns the key and two handlers never race for the same press.
    ///
    /// Events belonging to the settings or create-meeting windows are passed through: the monitor
    /// is app-wide, and those windows have their own Esc behaviour. An event with no window is
    /// still treated as the popover's, since that is the only window this view lives in.
    private func handleEscape(_ event: NSEvent) -> Bool {
        let popoverWindow = PostJoinDismissController.shared.registeredPopoverWindow
        guard event.window == nil || event.window === popoverWindow else { return false }

        if selectedEvent != nil {
            closeMeetingDetail()
        } else if isSearchBarPresented {
            closeSearch()
        } else {
            PostJoinDismissController.shared.dismissPopover()
        }
        return true
    }

    /// Single exit point for the detail card: the close button, a click beside it, and Esc.
    private func closeMeetingDetail() {
        withAnimation(.easeInOut(duration: 0.18)) {
            resetMeetingDetailState()
        }
    }

    private func toggleSearch() {
        withAnimation(.easeInOut(duration: 0.18)) {
            isSearchBarPresented.toggle()
        }
        if isSearchBarPresented {
            // Defer focus to the next runloop tick: the field is only inserted into the
            // hierarchy once `isSearchBarPresented` flips, so focusing synchronously here
            // targets a view that doesn't exist yet and is silently dropped.
            DispatchQueue.main.async {
                isSearchFieldFocused = true
            }
        } else {
            searchQuery = ""
        }
        resetMeetingDetailState()
    }

    private func closeSearch() {
        searchQuery = ""
        isSearchFieldFocused = false
        withAnimation(.easeInOut(duration: 0.18)) {
            isSearchBarPresented = false
        }
    }

    // MARK: - Error / empty states

    private var unreadableAccountStoreState: some View {
        VStack(spacing: 10) {
            Image(systemName: "lock.trianglebadge.exclamationmark")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(localization.tr("popover.accounts.unreadable.title"))
                .font(.system(size: 13, weight: .medium))
            Text(localization.tr("popover.accounts.unreadable.subtitle"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button { service.retryLoadingAccounts() } label: {
                Text(localization.tr("popover.retry"))
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Color.accentColor)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }

    private var noAccountState: some View {
        VStack(spacing: 10) {
            Image(systemName: "person.badge.plus")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(localization.tr("popover.no.accounts.title"))
                .font(.system(size: 13, weight: .medium))
            Text(localization.tr("popover.no.accounts.subtitle"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button { openSettings() } label: {
                Text(localization.tr("popover.open.settings"))
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Color.accentColor)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }

    private var errorState: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 24))
                .foregroundStyle(.orange)
            Text(localization.syncStatusText(service.syncStatus))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(localization.tr("popover.retry")) {
                // When auth is latched, syncNow() is a no-op (the breaker guard skips it), so
                // route through the breaker-lifting retry instead — same action as the footer.
                if service.syncStatus.isAuthenticationRequired {
                    service.retryAfterAuthBlock()
                } else {
                    service.syncNow()
                }
            }
            .font(.system(size: 12))
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Derived data

    private var now: Date { Date() }

    private var selectedDate: Date {
        AppTimeZone.calendar.date(byAdding: .day, value: selectedDayOffset,
            to: AppTimeZone.calendar.startOfDay(for: Date()))!
    }

    /// Meetings starting within 5 minutes of the earliest upcoming, sorted: with URL first
    private var nextEvents: [CalendarEvent] {
        NextEventsPolicy.nextEvents(from: service.events, now: now)
    }

    enum NextEventsPolicy {
        static func nextEvents(from events: [CalendarEvent], now: Date) -> [CalendarEvent] {
            let upcoming = events
                .filter {
                    !$0.isAllDay &&
                        !$0.isEffectivelyCancelled &&
                        ($0.startDate > now || $0.isHappeningNow)
                }
                .sorted { $0.startDate < $1.startDate }

            guard let earliest = upcoming.first else { return [] }

            // Only surface the banner for meetings starting within 30 minutes
            let secondsUntilEarliestStart = earliest.startDate.timeIntervalSince(now)
            guard secondsUntilEarliestStart <= 30 * 60 || earliest.isHappeningNow else { return [] }

            let promoted = upcoming.first {
                !$0.isHappeningNow && $0.startDate.timeIntervalSince(now) <= 5 * 60
            }
            let reference = promoted ?? earliest

            let group = upcoming.filter {
                abs($0.startDate.timeIntervalSince(reference.startDate)) <= 300
            }
            return group.sorted { ($0.joinURL != nil ? 0 : 1) < ($1.joinURL != nil ? 0 : 1) }
        }
    }

    // MARK: - Search

    /// Pure, UI-free meeting search over already-loaded events.
    /// Mirrors the `*Policy` pattern used elsewhere in this view so it can be unit-tested.
    enum MeetingSearchPolicy {
        struct DayGroup: Identifiable, Equatable {
            var id: Date { date }
            let date: Date
            let events: [CalendarEvent]
        }

        /// Splits text into words on any non-alphanumeric boundary. Used identically for
        /// both the query and the searchable fields so punctuation (apostrophes, hyphens)
        /// can't make the two sides tokenize differently — e.g. query "O'Brien" must split
        /// the same way as a field containing "O'Brien".
        static func words(in text: String) -> [Substring] {
            text.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        }

        /// `query` is split into word tokens; an event matches only when every token is a
        /// **word-start prefix** of at least one word across the searchable fields (AND
        /// across tokens). Matching on word boundaries — rather than substring anywhere —
        /// avoids short queries like "ai" matching inside transliterated words
        /// (e.g. "Михаил" → "mikhail"). Cross-script matching ("ivan" → "Иван", "ai" → "АИ")
        /// is preserved via `OWAPersonSearchTokenMatch.normalizedForms`.
        static func matches(_ event: CalendarEvent, query: String) -> Bool {
            let tokens = words(in: query).map(String.init)
            guard !tokens.isEmpty else { return false }

            var fields = [event.title]
            if let organizer = event.organizer { fields.append(organizer) }
            fields.append(contentsOf: event.attendees)
            if let location = event.location { fields.append(location) }
            if let body = event.bodyPreview { fields.append(body) }

            // Normalized (lowercased + Latin-transliterated) forms of every individual word.
            var wordForms = Set<String>()
            for field in fields {
                for word in words(in: field) {
                    wordForms.formUnion(OWAPersonSearchTokenMatch.normalizedForms(String(word)))
                }
            }
            guard !wordForms.isEmpty else { return false }

            return tokens.allSatisfy { token in
                let tokenForms = OWAPersonSearchTokenMatch.normalizedForms(token)
                guard !tokenForms.isEmpty else { return false }
                return tokenForms.contains { qf in
                    wordForms.contains { $0.hasPrefix(qf) }
                }
            }
        }

        /// Empty/whitespace query → no results. Cancelled and all-day events are kept;
        /// search should surface everything. Results are sorted by start date ascending.
        static func filter(_ events: [CalendarEvent], query: String) -> [CalendarEvent] {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return [] }
            return events
                .filter { matches($0, query: trimmed) }
                .sorted { $0.startDate < $1.startDate }
        }

        /// Groups events by calendar day, groups ordered ascending by date.
        /// The human-readable day label is produced by the view (it depends on localization).
        static func groupByDay(_ events: [CalendarEvent], calendar: Calendar) -> [DayGroup] {
            let buckets = Dictionary(grouping: events) { calendar.startOfDay(for: $0.startDate) }
            return buckets
                .map { DayGroup(date: $0.key, events: $0.value.sorted { $0.startDate < $1.startDate }) }
                .sorted { $0.date < $1.date }
        }
    }

    private var searchResultGroups: [MeetingSearchPolicy.DayGroup] {
        let filtered = MeetingSearchPolicy.filter(service.events, query: searchQuery)
        return MeetingSearchPolicy.groupByDay(filtered, calendar: AppTimeZone.calendar)
    }

    private var eventSections: [MeetingDaySection] {
        let calendar = AppTimeZone.calendar
        let dayStart = calendar.startOfDay(for: selectedDate)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)!

        return [
            MeetingDaySection.partition(
                events: service.events,
                label: localization.daySectionLabel(for: dayStart, calendar: calendar),
                dayStart: dayStart,
                dayEnd: dayEnd
            )
        ]
    }
}

private struct CompactCircularProgress: View {
    let progress: Double
    let title: String?
    var lineWidth: CGFloat = 3

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.22), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0, min(progress, 1)))
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if let title {
                Text(title)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 16, height: 16)
    }
}
