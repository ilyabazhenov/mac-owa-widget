import SwiftUI
import AppKit

/// The inbox panel beside the popover: invitations to answer, then the inbox itself, newest
/// first, exactly as the folder holds it — no guessing about what is important.
/// It lives in its own window, so it observes the services itself rather than taking snapshots.
struct PopoverInboxColumn: View {
    @ObservedObject var calendar: CalendarService
    @ObservedObject var mail: MailService
    let horizontalPadding: CGFloat
    let onSelectEvent: (CalendarEvent) -> Void
    let onOpenMail: (String?) -> Void
    let onCompose: () -> Void
    /// Opens the compose window on a request already handed to the service (a reply).
    let onShowCompose: () -> Void
    /// The message shown in place of the list; the popover owns it (Esc, closing).
    @ObservedObject var reader: InboxPanelReader

    private var invitations: [MeetingInvitationGroup] { calendar.popoverInvitationGroups }

    @EnvironmentObject private var localization: LocalizationService
    @State private var sending: [String: MeetingResponseAction] = [:]
    @State private var failed: Set<String> = []
    /// The folder tree shows in place of the list while the burger is on.
    @State private var showsFolders = false
    @State private var isRefreshing = false
    @State private var isMarkingRead = false
    /// The last "mark all read" failed: the badge is outlined and its tooltip says so.
    @State private var markReadFailed = false
    @StateObject private var swipes = MailSwipeController()

    private var showsMail: Bool { mail.isAvailable }

    private var folderTitle: String {
        if !showsMail || mail.panelFolder == .distinguished(.inbox) { return localization.tr("popover.inbox.title") }
        return mail.panelFolderInfo?.displayName ?? localization.tr("popover.inbox.title")
    }

    /// The inbox count comes from the regular check; other folders from the folder tree.
    private var folderUnread: Int? {
        mail.panelFolder == .distinguished(.inbox) ? mail.inboxUnreadCount : mail.panelFolderInfo?.unreadCount
    }


    private var isReading: Bool { reader.isOpen && showsMail }

    /// Deleted Items deletes nothing further, by swipe or from the message.
    private var folderAllowsDelete: Bool {
        mail.panelFolder != .distinguished(.deleteditems) && mail.panelFolderInfo?.distinguished != .deleteditems
    }

    /// The open message is deleted as its row would be (only the folder's messages, with Undo);
    /// a row a refresh already took away has nothing left to delete that way.
    private var openRowDeletable: Bool {
        folderAllowsDelete && mail.panelList.contains { $0.id == reader.conversationID }
    }

    var body: some View {
        let _ = PerfProbe.body("PopoverInboxColumn")
        VStack(spacing: 0) {
            if isReading { readerHeader } else { header }
            Divider()
            // The list stays under the message, hidden: going back finds it where it was.
            ZStack {
                listScroll
                    .opacity(isReading ? 0 : 1)
                    .allowsHitTesting(!isReading)
                    .accessibilityHidden(isReading)
                if isReading, let model = reader.model {
                    PopoverMailReaderView(
                        model: model,
                        mail: mail,
                        summary: mail.panelList.first { $0.id == reader.conversationID },
                        horizontalPadding: horizontalPadding,
                        canDelete: openRowDeletable,
                        onDelete: deleteOpenConversation,
                        onShowCompose: onShowCompose,
                        onOpenInWindow: { onOpenMail(reader.conversationID) }
                    )
                    .background(Color(nsColor: .windowBackgroundColor))
                    .transition(.move(edge: .trailing))
                }
            }
            .frame(maxHeight: .infinity)
            .clipped()
            .overlay(alignment: .bottom) {
                if let notice = mail.panelNotice {
                    MailListNoticeView(
                        notice: notice,
                        onUndo: { Task { await mail.undoPanelDelete() } },
                        onClose: { mail.dismissPanelNotice() }
                    )
                }
            }
            .animation(.easeInOut(duration: 0.18), value: mail.panelNotice)
            .animation(.easeInOut(duration: 0.18), value: isReading)
            Divider()
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .mailSwipeList(swipes, isEnabled: showsMail && mail.settings.swipeActionsEnabled && !mail.isBlocked && !isReading)
    }

    private var listScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if showsFolders {
                        folderTree
                    } else {
                        if !invitations.isEmpty {
                            sectionTitle(localization.tr("popover.inbox.invitations"), count: invitations.count)
                            ForEach(invitations) { invitationRow($0) }
                            Divider().padding(.top, 6)
                        }
                        if showsMail {
                            inboxList
                        } else {
                            if invitations.isEmpty { emptyState }
                            Text(localization.tr("popover.inbox.mailOff"))
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, horizontalPadding)
                                .padding(.top, 10)
                        }
                    }
                }
                .padding(.bottom, 10)
                // A row a swipe deleted (or Undo put back) closes the gap instead of jumping.
                .animation(.easeInOut(duration: 0.18), value: mail.panelRowsRevision)
            }
            // ↑/↓ in the reader may have walked off the rows that were on screen.
            .onChange(of: reader.conversationID) { id in
                guard id == nil, let last = reader.lastOpenedID else { return }
                proxy.scrollTo(last)
            }
        }
    }

    /// A click reads the message here; ⌘-click opens it in the mail window, as before.
    private func openConversation(_ conversation: MailConversationSummary) {
        if NSEvent.modifierFlags.contains(.command) {
            onOpenMail(conversation.id)
            return
        }
        reader.open(conversation.id, in: mail.panelFolder, service: mail)
    }

    /// Deletes the open conversation as a swipe would (with Undo) and goes back to the list.
    private func deleteOpenConversation() {
        guard folderAllowsDelete, let id = reader.conversationID,
              let summary = mail.panelList.first(where: { $0.id == id }) else { return }
        reader.close()
        Task { await mail.deletePanelConversation(summary) }
    }

    /// Back to the list, the next and previous message, and the mail window — in the place and
    /// type of the list's header, so the line under it does not move.
    private var readerHeader: some View {
        HStack(spacing: 6) {
            Button { reader.close() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                    Text(folderTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                }
                .frame(height: 16)
                .contentShape(Rectangle())
            }
            .buttonStyle(MailIconButtonStyle(horizontalPadding: 3, verticalPadding: 3))
            .padding(-3)
            .help(localization.tr("popover.inbox.back"))
            .accessibilityLabel(localization.tr("popover.inbox.back"))
            Spacer(minLength: 4)
            HStack {
                headerButton("chevron.up", "popover.inbox.previous") { reader.step(-1, service: mail) }
                    .disabled(!reader.canStep(-1, in: mail.panelList))
                headerButton("chevron.down", "popover.inbox.next") { reader.step(1, service: mail) }
                    .disabled(!reader.canStep(1, in: mail.panelList))
                headerButton("arrow.up.forward.square", "popover.inbox.openWindow") { onOpenMail(reader.conversationID) }
            }
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, 11)
    }

    /// Same type, padding and height as the popover's sync line, so the two bottom lines meet.
    private var footer: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack(spacing: 8) {
                switch mail.checkState {
                case .blocked:
                    Image(systemName: "exclamationmark.lock").foregroundStyle(.orange)
                    Text(localization.tr("popover.inbox.blocked")).lineLimit(1)
                case _ where mail.isOffline:
                    // No check goes out meanwhile, so the line says why rather than "failed".
                    Image(systemName: "wifi.slash").foregroundStyle(.orange)
                    Text(localization.tr("popover.inbox.offlineShort")).lineLimit(1)
                case .failed:
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text(localization.tr("mail.popover.failed")).lineLimit(1)
                default:
                    Text(showsMail
                         ? MailPresentation.panelStatus(unread: folderUnread, lastChecked: mail.lastChecked, now: context.date, localization: localization)
                         : localization.tr("popover.inbox.mailOffShort"))
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
            }
            .frame(height: 16)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, 7)
        }
    }

    /// The folder's conversations with the day sections and rows of the mail window; scrolling to the end loads the next page.
    @ViewBuilder
    private var inboxList: some View {
        let list = mail.panelList
        if list.isEmpty {
            // Empty means empty only once a request has come back: while one is on its way (a
            // folder switch, the first look) it says so, as the mail window's list does. While
            // sync is suspended nothing is requested at all, so it says that instead. A failure
            // (or no connection) stays on screen while "Retry" runs: the header spinner says a
            // new attempt is on its way, which without VPN takes the whole timeout.
            if mail.isBlocked {
                Text(localization.tr("popover.inbox.blocked"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else if mail.panelListFailed || mail.isOffline {
                VStack(spacing: 6) {
                    Text(localization.tr(mail.isOffline || mail.panelListFailedOnConnection ? "popover.inbox.offline" : "popover.inbox.loadFailed"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button(localization.tr("mail.retry")) { Task { await mail.refreshPanelList(minInterval: 0, evenOffline: true) } }
                        .controlSize(.small)
                        .disabled(mail.isLoadingPanelList)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, 24)
            } else if mail.isLoadingPanelList || !mail.panelListAnswered {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(localization.tr("mail.popover.loading"))
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                Text(localization.tr("popover.inbox.folderEmpty"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, horizontalPadding)
                    .padding(.vertical, 10)
            }
        } else {
            let starts = MailPresentation.sectionStarts(list.map(\.lastDelivery))
            ForEach(Array(list.enumerated()), id: \.element.id) { index, conversation in
                if let bucket = starts[index] {
                    sectionTitle(MailPresentation.sectionTitle(bucket, sample: conversation.lastDelivery, localization: localization), count: nil)
                }
                Button { openConversation(conversation) } label: {
                    MailConversationRow(
                        conversation: conversation,
                        isSelected: conversation.id == reader.lastOpenedID,
                        isSentFolder: mail.panelFolder.isSentItems,
                        terms: [],
                        folderName: nil,
                        compactPreview: true,
                        isExternal: conversation.hasExternalBanner || mail.isExternal(conversation.senderEmail),
                        meetingLine: MailPresentation.meetingLine(
                            conversation,
                            interval: conversation.isMeetingRequest ? mail.meetingInterval(forTopic: conversation.topic) : nil,
                            localization: localization
                        ),
                        underDaySection: true
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.mailRow(cornerRadius: 0))
                .mailSwipeActions(
                    swipes,
                    isUnread: conversation.isUnread,
                    canDelete: folderAllowsDelete,
                    onDelete: { Task { await mail.deletePanelConversation(conversation) } },
                    onToggleRead: { Task { await mail.togglePanelRead(conversation) } }
                )
                Divider().padding(.leading, 21)
            }
            if mail.panelNextCursor != nil {
                HStack(spacing: 6) {
                    if mail.isLoadingMorePanelList { ProgressView().controlSize(.small) }
                    Text(localization.tr("mail.list.loadingMore"))
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(10)
                .onAppear { Task { await mail.loadMorePanelList() } }
            }
        }
    }

    // MARK: - Pieces

    /// Same type and padding as the popover's own header, so the line under it continues the
    /// popover's.
    private var header: some View {
        HStack(spacing: 6) {
            if showsMail {
                folderMenu
            } else {
                Image(systemName: "tray")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.accentColor)
            }
            Text(folderTitle)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            if showsMail, isMarkingRead {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 16, height: 16)
                    .accessibilityLabel(localization.tr("popover.inbox.markingRead"))
            } else if showsMail, let unread = folderUnread, unread > 0 {
                unreadBadge(unread)
            }
            Spacer(minLength: 4)
            // The same row of plain icons as the calendar header beside it, with its default
            // spacing.
            if showsMail {
                HStack {
                    // Spins for the refresh button and for the panel's own background loads.
                    if isRefreshing || mail.isLoadingPanelList {
                        ProgressView()
                            .scaleEffect(0.6)
                            .frame(width: 16, height: 16)
                            .accessibilityLabel(localization.tr("popover.inbox.refresh"))
                    } else {
                        headerButton("arrow.clockwise", "popover.inbox.refresh") { refresh() }
                    }
                    headerButton("square.and.pencil", "popover.inbox.compose") { onCompose() }
                    headerButton("arrow.up.forward.square", "popover.inbox.openWindow") { onOpenMail(nil) }
                }
            }
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, 11)
    }

    /// Opens the folder tree in the panel itself: all folders at once, subfolders right under
    /// their parent (a menu would hide the inbox's rule folders two submenus deep).
    private var folderMenu: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { showsFolders.toggle() }
            if showsFolders {
                Task {
                    await mail.loadFoldersIfNeeded()
                    await mail.refreshFolderCounts()
                }
            }
        } label: {
            Image(systemName: showsFolders ? "xmark" : "line.3.horizontal")
                .font(.system(size: 13))
                .foregroundStyle(Color.accentColor)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(MailIconButtonStyle(horizontalPadding: 3, verticalPadding: 3))
        .padding(-3)
        .help(localization.tr(showsFolders ? "popover.inbox.foldersClose" : "popover.inbox.folders"))
        .accessibilityLabel(localization.tr(showsFolders ? "popover.inbox.foldersClose" : "popover.inbox.folders"))
    }

    @ViewBuilder
    private var folderTree: some View {
        let rows = MailPanelFolderList.rows(mail.folders)
        if rows.isEmpty {
            Text(localization.tr("mail.popover.loading"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, 10)
        } else {
            ForEach(rows, id: \.folder.id) { row in
                if row.startsCustom {
                    Divider().padding(.vertical, 4).padding(.horizontal, horizontalPadding)
                }
                folderRow(row.folder, depth: row.depth)
            }
            .padding(.top, 4)
        }
    }

    private func folderRow(_ folder: MailFolder, depth: Int) -> some View {
        let ref: MailFolderRef = folder.distinguished.map { .distinguished($0) } ?? .id(folder.id)
        let isShown = ref == mail.panelFolder
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) { showsFolders = false }
            Task { await mail.selectPanelFolder(ref) }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: MailPresentation.folderIcon(folder))
                    .font(.system(size: 12))
                    .foregroundStyle(isShown ? Color.accentColor : Color.secondary)
                    .frame(width: 16)
                Text(folder.displayName)
                    .font(.system(size: 12, weight: folder.unreadCount > 0 ? .semibold : .regular))
                    .lineLimit(1)
                Spacer(minLength: 6)
                if folder.unreadCount > 0, folder.distinguished != .sentitems {
                    Text("\(folder.unreadCount)")
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.leading, CGFloat(depth) * 16 + 8)
            .padding(.trailing, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(isShown ? Color.accentColor.opacity(0.16) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.mailRow)
        .padding(.horizontal, horizontalPadding - 6)
    }

    /// The unread count opens a one-item menu to mark the folder read: the second click is the
    /// confirmation, with no dialog over the panel.
    private func unreadBadge(_ unread: Int) -> some View {
        Menu {
            Button(localization.tr("popover.inbox.markAllRead", unread)) { markAllRead() }
        } label: {
            Text("\(unread)")
                .font(.system(size: 10, weight: .semibold))
                .monospacedDigit()
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.accentColor.opacity(markReadFailed ? 0 : 0.18)))
                .overlay(Capsule().stroke(Color.orange, lineWidth: markReadFailed ? 1 : 0))
                .foregroundStyle(Color.accentColor)
                .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(markReadFailed
              ? localization.tr("popover.inbox.markReadFailed")
              : localization.tr("popover.inbox.unreadHelp", folderTitle, unread))
    }

    private func markAllRead() {
        guard !isMarkingRead else { return }
        isMarkingRead = true
        markReadFailed = false
        Task {
            do {
                try await mail.markPanelFolderRead()
            } catch {
                markReadFailed = true
            }
            isMarkingRead = false
        }
    }

    private func headerButton(_ icon: String, _ key: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .frame(width: 16, height: 16)
        }
        .buttonStyle(MailIconButtonStyle(horizontalPadding: 3, verticalPadding: 3))
        .padding(-3)
        .help(localization.tr(key))
        .accessibilityLabel(localization.tr(key))
    }

    private func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task {
            await mail.checkInbox(evenOffline: true)
            // The check reloads the list itself when the unread count moved: not twice then.
            // A check that got through also clears "offline"; one that did not leaves it, and the
            // list then waits no second timeout.
            await mail.refreshPanelList(minInterval: 3)
            await mail.refreshFolderCounts(minInterval: 0)
            isRefreshing = false
        }
    }

    private func sectionTitle(_ title: String, count: Int?) -> some View {
        HStack(spacing: 5) {
            Text(title)
            if let count, count > 0 {
                Text("\(count)").monospacedDigit().foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, horizontalPadding)
        .padding(.top, 10)
        .padding(.bottom, 3)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "checkmark.circle").font(.system(size: 22)).foregroundStyle(.tertiary)
            Text(localization.tr("popover.inbox.empty")).font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    private func invitationRow(_ group: MeetingInvitationGroup) -> some View {
        let event = group.representative
        let action = sending[group.id]
        return HStack(spacing: 6) {
            Button { onSelectEvent(event) } label: {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(event.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        if group.occurrenceCount > 1 {
                            Text("×\(group.occurrenceCount)").font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                    Text(failed.contains(group.id) ? localization.tr("popover.inbox.respondFailed") : InvitationLabel.when(event, localization: localization))
                        .font(.system(size: 11))
                        .foregroundStyle(failed.contains(group.id) ? Color.orange : Color.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(event.organizer.map { localization.tr("invitations.pending.organizer", $0) } ?? event.title)

            if let action {
                ProgressView().controlSize(.small)
                    .help(localization.tr(action == .accept ? "popover.inbox.accept" : "popover.inbox.sending"))
            } else {
                Button(localization.tr("popover.inbox.accept")) { respond(group, .accept) }
                    .controlSize(.small)
                Menu {
                    Button(localization.tr("popover.inbox.tentative")) { respond(group, .tentative) }
                    Button(localization.tr("popover.inbox.decline")) { respond(group, .decline) }
                    Divider()
                    Button(localization.tr("invitations.action.hide")) {
                        calendar.dismissInvitations(eventIDs: group.events.map(\.id))
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(localization.tr("popover.inbox.more"))
            }
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, 4)
    }

    private func respond(_ group: MeetingInvitationGroup, _ action: MeetingResponseAction) {
        guard sending[group.id] == nil else { return }
        sending[group.id] = action
        failed.remove(group.id)
        Task { @MainActor in
            do {
                try await calendar.respondToMeeting(group.representative, action: action)
            } catch {
                failed.insert(group.id)
            }
            sending[group.id] = nil
        }
    }
}

/// "Today, 14:00", "Tomorrow, 9:30", "Fri, 26 Sep, 11:00" for invitation rows.
enum InvitationLabel {
    @MainActor
    static func when(_ event: CalendarEvent, localization: LocalizationService) -> String {
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
