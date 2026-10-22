import SwiftUI
import AppKit

struct PopoverView: View {
    @EnvironmentObject var service: CalendarService
    /// Read, not observed: the popover is the whole calendar, and observing the service redrew it
    /// for every change there (each row a swipe takes out, each count, each page). It redraws for
    /// mail when `mailChrome` — the part of mail it shows itself — changes; the inbox panel and
    /// the mail strip observe the service on their own.
    private let mail: MailService
    @ObservedObject private var mailChrome: MailPopoverChrome
    @EnvironmentObject private var localization: LocalizationService
    @EnvironmentObject private var updateCheck: UpdateCheckService
    @EnvironmentObject private var colleagues: ColleaguePresenceService
    @StateObject private var colleaguesSection = ColleaguesSectionModel()
    /// The message the inbox panel shows in place of its list.
    @StateObject private var inboxReader = InboxPanelReader()
    @Environment(\.openWindow) private var openWindow
    private var popoverSize: PopoverSize { service.popoverSize }
    let contentHorizontalPadding: CGFloat = 12
    @AppStorage(PopoverInboxPanelStore.key) private var inboxPanelShown = false
    /// The panel found room beside the popover; until it says otherwise, assume it did.
    @State private var inboxPanelPlaced = true
    @State private var selectedDayOffset: Int = 0
    /// Direction of the last day step, which is what the page slide follows.
    @State private var isPagingForward: Bool = true
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

    init(mail: MailService) {
        self.mail = mail
        _mailChrome = ObservedObject(wrappedValue: mail.popoverChrome)
    }

    var body: some View {
        let _ = PerfProbe.body("PopoverView")
        // The meeting card floats over the entire popover — colleagues section and footer
        // included — rather than only over the timeline. Expanding the colleagues block then
        // costs the card no height at all: it always opens against the full window.
        ZStack(alignment: .bottom) {
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
                // Under the meeting list, with a height that follows the rows on screen and stops at
                // the row limit. Thirty watched colleagues cost the timeline exactly what four do.
                if colleagues.isSectionVisible {
                    Divider()
                    ColleaguesSectionHeaderView(
                        model: colleaguesSection,
                        horizontalPadding: contentHorizontalPadding,
                        onJoin: joinColleagueRoom
                    )
                    if colleaguesSection.isExpanded {
                        ColleaguesPanelView(
                            model: colleaguesSection,
                            horizontalPadding: contentHorizontalPadding,
                            onJoin: joinColleagueRoom
                        )
                    }
                }
                Divider()
                footer
            }
            .accessibilityHidden(selectedEvent != nil)
            .overlay {
                if selectedEvent != nil {
                    // The dimmed area doubles as the dismiss target: clicking beside the card
                    // closes it, the way a sheet behaves. It also stops a click from landing on
                    // the timeline (or a colleague row) underneath.
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
        .frame(width: CGFloat(popoverSize.width), height: CGFloat(popoverSize.height))
        .background(Color(nsColor: .windowBackgroundColor))
        .background {
            PopoverWindowRegistrar()
                .frame(width: 0, height: 0)
        }
        .background {
            PopoverInboxPanelAttachment(
                isEnabled: showsInboxPanel && !service.accounts.isEmpty,
                width: CGFloat(popoverSize.width),
                content: inboxPanelContent,
                onShow: {
                    guard mail.isAvailable else { return }
                    mail.popoverDidAppear()
                    // A message read in the panel needs the reader's network block in place
                    // before its body loads; compiling it takes a moment, so it starts now.
                    MailContentBlocker.prepare()
                    Task {
                        await mail.refreshPanelList()
                        await mail.refreshFolderCounts()
                    }
                },
                onPlacementChange: { inboxPanelPlaced = $0 }
            )
            .frame(width: 0, height: 0)
        }
        .animation(.easeInOut(duration: 0.16), value: colleaguesSection.isExpanded)
        .animation(.easeInOut(duration: 0.18), value: selectedEvent?.id)
        .onEscapeKey(perform: handleEscape)
        .background(MailKeyboardMonitor(handle: handleReaderKey))
        .onChange(of: showsInboxPanel) { shown in
            if !shown { inboxReader.close(forget: true) }
        }
        // No room beside the popover: the panel hides, and its message must not keep Esc and ↑/↓.
        .onChange(of: inboxPanelPlaced) { placed in
            if !placed { inboxReader.close(forget: true) }
        }
        .onHorizontalPagingSwipe(
            isEnabled: { isDayPagingBySwipeEnabled },
            perform: handlePagingSwipe
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(localization.tr("app.name"))
        .onAppear {
            colleagues.popoverDidAppear()
            applyEventFocusRequest()
        }
        .onChange(of: service.eventFocusRequest) { _ in
            applyEventFocusRequest()
        }
        #if DEBUG || PERF_HARNESS
        // Lets a measuring or screenshot script page the day (see `PerfProbe`).
        .onReceive(NotificationCenter.default.publisher(for: PerfProbe.harnessStepDay)) { note in
            if let delta = note.object as? Int { goToDay(offsetBy: delta) }
        }
        #endif
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: PerfProbe.harnessForceAuthBlock)) { note in
            if note.object as? String == "clearevents" {
                service.replaceEventsForTests([])
            } else {
                service.debugForceAuthBlock()
            }
        }
        #endif
        .onDisappear {
            resetMeetingDetailState()
            // The panel opens on its list again next time.
            inboxReader.close(forget: true)
            searchQuery = ""
            isSearchBarPresented = false
        }
    }

    // MARK: - Header

    /// Named after what it shows, like the inbox panel beside it ("Inbox | Calendar"); the app
    /// itself is already the menu-bar icon, and its version sits in Settings › About.
    private var header: some View {
        HStack {
            HStack(spacing: 6) {
                Image(systemName: "calendar")
                    .font(.app(.headline))
                    .foregroundStyle(Color.accentColor)
                Text(localization.tr("popover.calendar.title"))
                    .font(.app(.headline, weight: .semibold))
            }

            Spacer()

            Button { toggleSearch() } label: {
                Image(systemName: "magnifyingglass")
                    .font(.app(.headline))
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
                    colleagues.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.app(.headline))
                }
                .buttonStyle(.plain)
                .help(localization.tr("popover.sync.now"))
                .accessibilityLabel(localization.tr("popover.sync.now"))
            }

            if mail.isAvailable {
                // Shows or hides the inbox panel; the mail window opens from the panel itself.
                // With mail kept out of the popover there is no panel, and the envelope opens the
                // mail window straight away.
                Button {
                    if mail.showsPopoverSection {
                        inboxPanelShown.toggle()
                    } else {
                        openMail(nil)
                    }
                } label: {
                    Image(systemName: showsInboxPanel ? "envelope.fill" : "envelope")
                        .font(.app(.headline))
                        .foregroundStyle(showsInboxPanel ? Color.accentColor : .primary)
                        .overlay(alignment: .topTrailing) {
                            // Not there while the panel is open, so nothing then follows the count.
                            if !showsInboxPanel { PopoverMailUnreadBadge(mail: mail) }
                        }
                }
                .buttonStyle(.plain)
                .help(localization.tr(envelopeHelpKey))
                .accessibilityLabel(localization.tr(envelopeHelpKey))
            }

            if service.supportsMeetingCreation {
                Button { openCreateMeeting() } label: {
                    Image(systemName: "plus")
                        .font(.app(.headline))
                }
                .buttonStyle(.plain)
                .help(localization.tr("popover.new.meeting"))
                .accessibilityLabel(localization.tr("popover.new.meeting"))
            }

            // Quit is no longer a button of its own beside search and "+", where a stray click
            // closed the app and its reminders with it. It lives in the gear's context menu, in
            // the menu bar icon's menu and on ⌘Q.
            Button { openSettings() } label: {
                Image(systemName: "gearshape")
                    .font(.app(.headline))
            }
            .buttonStyle(.plain)
            .help(localization.tr("popover.settings"))
            .accessibilityLabel(localization.tr("popover.settings"))
            .contextMenu {
                Button(localization.tr("popover.settings") + "…") { openSettings() }
                Divider()
                Button(localization.tr("popover.quit")) { quitApp() }
            }
            .accessibilityAction(named: Text(localization.tr("popover.quit"))) { quitApp() }
        }
        .padding(.horizontal, contentHorizontalPadding)
        .padding(.vertical, 11)
        .accessibilitySortPriority(selectedEvent == nil ? 1 : 0)
    }

    /// Quick popover-size switcher, writing straight through to the shared service.
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
                .font(.app(.caption))
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
        Group {
            if isSearching {
                SearchResultsView(
                    groups: searchResultGroups,
                    contentHorizontalPadding: contentHorizontalPadding,
                    selectedEventID: selectedEvent?.id,
                    onSelect: selectEvent
                )
            } else if showsInboxPanel, inboxPanelPlaced {
                // The inbox has its own panel beside the popover: no strips that would read as
                // belonging to the date above them. With no room for the panel the strips stay.
                calendarColumn(showsInboxStrips: false)
            } else {
                calendarColumn(showsInboxStrips: true)
            }
        }
    }

    /// The panel needs mail: without it the envelope that toggles it is not there either. With
    /// mail kept out of the popover the panel stays closed, and `inboxPanelShown` is left as it
    /// was, so turning mail back on brings the panel back as the user left it.
    private var showsInboxPanel: Bool { inboxPanelShown && mail.showsPopoverSection }

    private var envelopeHelpKey: String {
        guard mail.showsPopoverSection else { return "mail.popover.open" }
        return inboxPanelShown ? "popover.inbox.hide" : "popover.inbox.show"
    }

    private var inboxPanelContent: AnyView {
        AnyView(
            InboxPanelRoot(localization: localization) {
                PopoverInboxColumn(
                    calendar: service,
                    mail: mail,
                    horizontalPadding: contentHorizontalPadding,
                    onSelectEvent: focus(on:),
                    onOpenMail: openMail,
                    onCompose: openMailCompose,
                    onShowCompose: showComposeWindow,
                    reader: inboxReader
                )
            }
            // The panel never becomes key (that would close the popover), and AppKit draws the
            // controls of a non-key window dimmed: they would not match the popover's beside it.
            .environment(\.controlActiveState, .key)
        )
    }

    /// The date bar and the day; in the single-column layout also the mail and invitation strips.
    private func calendarColumn(showsInboxStrips: Bool) -> some View {
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
            if showsInboxStrips, mail.showsPopoverSection {
                MailPopoverSectionView(
                    mail: mail,
                    horizontalPadding: contentHorizontalPadding,
                    onOpen: openMail
                )
                Divider()
            }
            let popoverInvitations = showsInboxStrips ? service.popoverInvitationGroups : []
            if !popoverInvitations.isEmpty {
                PendingInvitationsSectionView(
                    groups: popoverInvitations,
                    horizontalPadding: contentHorizontalPadding,
                    onSelect: focus(on:),
                    onDismiss: { service.dismissInvitations(eventIDs: $0.events.map(\.id)) }
                )
                Divider()
            }
            // Both days are on screen for the length of the slide, so they are stacked
            // rather than laid out in sequence: a VStack would briefly squeeze each into
            // half the height. Clipping keeps the leaving day inside the timeline area.
            ZStack(alignment: .top) {
                dayBody
                    .id(selectedDayOffset)
                    .transition(dayPageTransition)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
    }

    /// Everything that belongs to one particular day, and therefore everything that slides when
    /// the day changes. The bars above it stay put.
    private var dayBody: some View {
        VStack(spacing: 0) {
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
                onSelect: selectEvent,
                // The date bar right above already names the day.
                showsDayLabel: false,
                emptyMessage: localization.tr(isAwaitingFirstSync ? "popover.day.loading" : "popover.day.empty"),
                isLoading: isAwaitingFirstSync
            )
        }
    }

    /// The new day arrives from the side it lies on and pushes the old one off the opposite
    /// edge, so the motion reads as a page moving under the swipe rather than a plain redraw.
    private var dayPageTransition: AnyTransition {
        let arrivingEdge: Edge = isPagingForward ? .trailing : .leading
        let leavingEdge: Edge = isPagingForward ? .leading : .trailing
        return .asymmetric(
            insertion: .move(edge: arrivingEdge).combined(with: .opacity),
            removal: .move(edge: leavingEdge).combined(with: .opacity)
        )
    }

    /// The row carries no horizontal padding of its own: each arrow folds that padding into its
    /// own hit rectangle instead, so the two targets run all the way to the popover's edges.
    private var dateNavBar: some View {
        HStack(spacing: 0) {
            DayNavArrowButton(
                direction: .previous,
                isEnabled: DateNavBarPolicy.canGoToPreviousDay(
                    selectedDayOffset: selectedDayOffset,
                    minDayOffset: minDayOffset
                ),
                accessibilityLabel: localization.tr("a11y.nav.previous.day"),
                innerInset: contentHorizontalPadding
            ) {
                goToDay(offsetBy: -1)
            }

            Spacer(minLength: 0)

            // The label travels with the page. On a day with no meetings it is the only thing
            // that moves, and without it a swipe there would look like nothing happened.
            ZStack {
                HStack(spacing: 6) {
                    Text(localization.daySectionLabel(for: selectedDate, calendar: AppTimeZone.calendar))
                        .font(.app(.body, weight: .semibold))
                    TimeZoneBadge()
                }
                .id(selectedDayOffset)
                .transition(dayPageTransition)
            }
            .clipped()

            Spacer(minLength: 0)

            if DateNavBarPolicy.shouldShowJumpToToday(selectedDayOffset: selectedDayOffset) {
                Button {
                    goToToday()
                } label: {
                    let icon = selectedDayOffset < 0 ? "arrow.uturn.forward.circle" : "arrow.uturn.backward.circle"
                    Label(localization.tr("popover.nav.today"), systemImage: icon)
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.plain)
                .font(.app(.footnote, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .accessibilityLabel(localization.tr("a11y.nav.today"))
            }

            DayNavArrowButton(
                direction: .next,
                isEnabled: DateNavBarPolicy.canGoToNextDay(
                    selectedDayOffset: selectedDayOffset,
                    maxDayOffset: maxDayOffset
                ),
                accessibilityLabel: localization.tr("a11y.nav.next.day"),
                innerInset: contentHorizontalPadding
            ) {
                goToDay(offsetBy: 1)
            }
        }
        .padding(.vertical, 3)
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
                        .font(.app(.micro))
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
                    .font(.app(.footnote, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .help(service.syncStatus.isAuthenticationRequired
                        ? localization.tr("popover.retry.help")
                        : localization.tr("popover.sync.now"))
                }

                // What blocks sync (a password, a certificate, a login host) is fixed in Settings.
                if service.syncStatus.blocksSync {
                    Button(localization.tr("popover.settings")) { openSettings() }
                        .buttonStyle(.plain)
                        .font(.app(.footnote, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .help(localization.tr("popover.open.settings"))
                }

                Spacer(minLength: 8)

                // The version is in Settings › About, with the build number.
                popoverSizeMenu
            }
                // The smallest reading size: the status line is read, not glanced at.
                .font(.app(.footnote))
                .foregroundStyle(.secondary)
                .padding(.horizontal, contentHorizontalPadding)
                .padding(.vertical, 7)
        }
    }

    private func openCreateMeeting() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "create-meeting")
    }

    private func openMailCompose() {
        mail.compose(MailComposeRequest(kind: .new, original: nil, to: [], cc: [], subject: "", body: ""))
        showComposeWindow()
    }

    /// The compose window on whatever request the service holds (new mail, a reply from the panel).
    private func showComposeWindow() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "mail-compose")
        PostJoinDismissController.shared.dismissPopover()
    }

    private func openMail(_ conversationID: String?) {
        NSApp.activate(ignoringOtherApps: true)
        // With the inbox panel on, the window opens on the panel's folder.
        let folder = showsInboxPanel ? mail.panelFolder : nil
        if conversationID != nil || folder != nil { mail.open(conversationID: conversationID ?? "", folder: folder) }
        openWindow(id: "mail")
        // The mail window takes over; a click in the inbox panel never takes focus from the
        // popover, so the popover would otherwise stay open on top of it.
        PostJoinDismissController.shared.dismissPopover()
    }

    private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "settings")
    }

    private func quitApp() {
        NSApp.terminate(nil)
    }

    private func joinColleagueRoom(_ url: URL) {
        guard MeetingURLOpener.open(url) else { return }
        PostJoinDismissController.shared.dismissAfterJoin(context: .popoverContent)
    }

    /// Single entry point for stepping the day, shared by the arrows, the swipe and the "today"
    /// button, so the bounds and the slide are decided in one place.
    private func goToDay(offsetBy delta: Int) {
        let target = selectedDayOffset + delta
        guard target != selectedDayOffset, target >= minDayOffset, target <= maxDayOffset else { return }

        // The direction is committed in its own render pass, before the day itself moves, and
        // that ordering is the whole point. A transition has two halves, and the removal half
        // belongs to the page being torn down — which carries whichever transition was attached
        // to it the last time it was rendered. Flipping the direction in the same pass that
        // changes the id would leave the outgoing page with the previous step's removal edge, so
        // the first swipe back after a swipe forward would send both pages off the same side.
        // Letting the current page re-render with the new direction first closes that window.
        isPagingForward = delta > 0
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.22)) {
                selectedDayOffset = target
            }
        }
        resetMeetingDetailState()
    }

    private func goToToday() {
        goToDay(offsetBy: -selectedDayOffset)
    }

    private func handlePagingSwipe(_ step: HorizontalSwipePagingPolicy.Step) {
        let delta = step == .previous ? -1 : 1
        let target = selectedDayOffset + delta
        // A swipe is a blind gesture: without a tick the user cannot tell a refused step at the
        // range's edge from one that simply did not register. So the two feel different.
        guard target >= minDayOffset, target <= maxDayOffset else {
            DayPagingHaptics.pageRefused()
            return
        }
        goToDay(offsetBy: delta)
        DayPagingHaptics.pageTurned()
    }

    /// Swiping pages the date bar, so it is live exactly when that bar is on screen: not behind
    /// the modal meeting card, not while search replaces the day view, and not on the empty or
    /// error states, which show no date at all.
    private var isDayPagingBySwipeEnabled: Bool {
        guard selectedEvent == nil, !isSearching, !service.accounts.isEmpty else { return false }
        return !SyncPresentationPolicy.shouldShowErrorState(
            syncStatus: service.syncStatus,
            eventsCount: service.events.count
        )
    }

    private func selectEvent(_ event: CalendarEvent) {
        withAnimation(.easeInOut(duration: 0.18)) {
            selectedEvent = event
        }
    }

    /// Shows a meeting that may lie on another day: moves the timeline there and opens its card.
    private func focus(on event: CalendarEvent) {
        let calendar = AppTimeZone.calendar
        let today = calendar.startOfDay(for: Date())
        let day = calendar.startOfDay(for: event.startDate)
        let offset = calendar.dateComponents([.day], from: today, to: day).day ?? 0
        if isSearchBarPresented { closeSearch() }
        let target = min(max(offset, minDayOffset), maxDayOffset)
        if target != selectedDayOffset {
            isPagingForward = target > selectedDayOffset
            selectedDayOffset = target
        }
        selectEvent(event)
    }

    /// Consumes a request raised outside the popover — "Open" on the invitation panel.
    private func applyEventFocusRequest() {
        guard let request = service.eventFocusRequest else { return }
        service.clearEventFocusRequest()
        guard let event = service.events.first(where: { $0.id == request.eventID }) else { return }
        focus(on: event)
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

        // Typing in a field of the popover: Esc is for that field first, the panel's message after.
        let isTyping = popoverWindow?.firstResponder is NSText
        if selectedEvent != nil {
            closeMeetingDetail()
        } else if inboxReader.isOpen, !isTyping {
            inboxReader.close()
        } else if colleaguesSection.handleEscape() {
            // Handled inside the section: the card or the search box first, the panel after.
        } else if isSearchBarPresented {
            closeSearch()
        } else if inboxReader.isOpen {
            inboxReader.close()
        } else {
            PostJoinDismissController.shared.dismissPopover()
        }
        return true
    }

    /// The C key (`kVK_ANSI_C`), wherever the layout puts its letter.
    private static let cKeyCode: UInt16 = 8
    /// The Q key (`kVK_ANSI_Q`).
    private static let qKeyCode: UInt16 = 12

    /// ⌘Q quits from the popover, now that it has no quit button. Otherwise ↑/↓ walk the inbox
    /// panel's list while it shows a message: the panel never takes focus, so its keys arrive at
    /// the popover. Typing in a field here is left alone by the monitor.
    private func handleReaderKey(_ event: NSEvent) -> Bool {
        // By the key, not its character: in the Russian layout ⌘Q arrives as "й".
        if event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command,
           event.keyCode == Self.qKeyCode {
            quitApp()
            return true
        }
        guard inboxReader.isOpen, mail.isAvailable else { return false }
        // ⌘C copies what is selected in the message; the monitor leaves ⌘C in a text field alone.
        // By the key, not its character: in the Russian layout ⌘C arrives as "с" (Cyrillic).
        if event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command,
           event.keyCode == Self.cKeyCode {
            return MailReaderWebView.copyInboxPanelSelection()
        }
        guard event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return false }
        switch event.keyCode {
        case 126: inboxReader.step(-1, service: mail)
        case 125: inboxReader.step(1, service: mail)
        default: return false
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
                .font(.app(.symbol))
                .foregroundStyle(.secondary)
            Text(localization.tr("popover.accounts.unreadable.title"))
                .font(.app(.headline, weight: .medium))
            Text(localization.tr("popover.accounts.unreadable.subtitle"))
                .font(.app(.footnote))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button { service.retryLoadingAccounts() } label: {
                Text(localization.tr("popover.retry"))
                    .font(.app(.body, weight: .medium))
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

    /// The first thing a new user sees: what the app is for, and the one step to get there.
    private var noAccountState: some View {
        VStack(spacing: 14) {
            Image(systemName: "calendar.badge.clock")
                .font(.app(.symbol))
                .foregroundStyle(Color.accentColor)
                .symbolRenderingMode(.hierarchical)
            VStack(spacing: 6) {
                Text(localization.tr("popover.welcome.title"))
                    .font(.app(.title, weight: .semibold))
                Text(localization.tr("popover.welcome.subtitle"))
                    .font(.app(.footnote))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 8) {
                welcomePoint("video", "popover.welcome.point.join")
                welcomePoint("bell", "popover.welcome.point.remind")
                welcomePoint("person.2", "popover.welcome.point.accounts")
            }
            .padding(.vertical, 4)
            Button { openSettings() } label: {
                Text(localization.tr("popover.welcome.action"))
                    .font(.app(.body, weight: .semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(Color.accentColor)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }

    private func welcomePoint(_ symbol: String, _ key: String) -> some View {
        Label {
            Text(localization.tr(key))
                .font(.app(.footnote))
        } icon: {
            Image(systemName: symbol)
                .font(.app(.footnote))
                .foregroundStyle(Color.accentColor)
                .frame(width: 18)
        }
    }

    private var errorState: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.app(.symbol))
                .foregroundStyle(.orange)
            Text(localization.syncStatusText(service.syncStatus))
                .font(.app(.body))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 8) {
                Button(localization.tr("popover.retry")) {
                    // When auth is latched, syncNow() is a no-op (the breaker guard skips it), so
                    // route through the breaker-lifting retry instead — same action as the footer.
                    if service.syncStatus.isAuthenticationRequired {
                        service.retryAfterAuthBlock()
                    } else {
                        service.syncNow()
                    }
                }
                // A password, a certificate or a login host is fixed in Settings: the way there
                // sits next to the message instead of being left for the user to find.
                if service.syncStatus.blocksSync {
                    Button(localization.tr("popover.open.settings")) { openSettings() }
                }
            }
            .font(.app(.body))
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

    /// Nothing has arrived from the calendar yet and a sync is on its way: an empty day then
    /// means "loading", not "free".
    private var isAwaitingFirstSync: Bool {
        guard service.events.isEmpty else { return false }
        switch service.syncStatus {
        case .idle, .syncing: return true
        default: return false
        }
    }

    /// Meetings starting within 5 minutes of the earliest upcoming, sorted: with URL first
    private var nextEvents: [CalendarEvent] {
        NextMeetingGroupPolicy.bannerGroup(from: service.events, now: now)
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

/// The root of the inbox panel. Its content is set once (the panel is a window of its own), so
/// the locale follows the language from in here rather than being read when the content is built.
private struct InboxPanelRoot<Content: View>: View {
    @ObservedObject var localization: LocalizationService
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .environmentObject(localization)
            .environment(\.locale, localization.locale)
    }
}

/// The inbox count on the popover's envelope. It observes the service itself, so a change in the
/// count redraws this badge rather than the popover around it.
private struct PopoverMailUnreadBadge: View {
    @ObservedObject var mail: MailService

    var body: some View {
        if let unread = mail.inboxUnreadCount, unread > 0 {
            Text(unread > 99 ? "99+" : "\(unread)")
                .font(.app(.micro, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 3)
                .frame(minWidth: 12, minHeight: 12)
                .background(Capsule().fill(Color.accentColor))
                .offset(x: 7, y: -6)
        }
    }
}
