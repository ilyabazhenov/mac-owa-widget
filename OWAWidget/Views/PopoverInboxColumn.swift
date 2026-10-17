import SwiftUI

/// The inbox panel beside the popover: invitations to answer, then the inbox itself, newest
/// first, exactly as the folder holds it — no guessing about what is important.
/// It lives in its own window, so it observes the services itself rather than taking snapshots.
struct PopoverInboxColumn: View {
    @ObservedObject var calendar: CalendarService
    @ObservedObject var mail: MailService
    let horizontalPadding: CGFloat
    let onSelectEvent: (CalendarEvent) -> Void
    let onOpenMail: (String?) -> Void

    private var invitations: [MeetingInvitationGroup] { calendar.popoverInvitationGroups }

    @EnvironmentObject private var localization: LocalizationService
    @State private var sending: [String: MeetingResponseAction] = [:]
    @State private var failed: Set<String> = []
    /// The folder tree shows in place of the list while the burger is on.
    @State private var showsFolders = false

    private var showsMail: Bool { mail.isAvailable }

    private var folderTitle: String {
        if !showsMail || mail.panelFolder == .distinguished(.inbox) { return localization.tr("popover.inbox.title") }
        return mail.panelFolderInfo?.displayName ?? localization.tr("popover.inbox.title")
    }

    /// The inbox count comes from the regular check; other folders from the folder tree.
    private var folderUnread: Int? {
        mail.panelFolder == .distinguished(.inbox) ? mail.inboxUnreadCount : mail.panelFolderInfo?.unreadCount
    }


    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
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
            }
            .frame(maxHeight: .infinity)
            Divider()
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// Same type, padding and height as the popover's sync line, so the two bottom lines meet.
    private var footer: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack(spacing: 8) {
                switch mail.checkState {
                case .blocked:
                    Image(systemName: "exclamationmark.lock").foregroundStyle(.orange)
                    Text(localization.tr("popover.inbox.blocked")).lineLimit(1)
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
                if showsMail {
                    Button {
                        Task {
                            await mail.checkInbox()
                            await mail.refreshPanelList(minInterval: 0)
                            await mail.refreshFolderCounts(minInterval: 0)
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .help(localization.tr("popover.inbox.refresh"))
                    .accessibilityLabel(localization.tr("popover.inbox.refresh"))
                }
            }
            .frame(height: 16)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, 7)
        }
    }

    /// The inbox's first page with the day sections and rows of the mail window.
    @ViewBuilder
    private var inboxList: some View {
        let list = mail.panelList
        if list.isEmpty {
            Text(localization.tr(mail.lastChecked == nil ? "mail.popover.loading" : "popover.inbox.folderEmpty"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, 10)
        } else {
            let starts = MailPresentation.sectionStarts(list.map(\.lastDelivery))
            ForEach(Array(list.enumerated()), id: \.element.id) { index, conversation in
                if let bucket = starts[index] {
                    sectionTitle(MailPresentation.sectionTitle(bucket, sample: conversation.lastDelivery, localization: localization), count: nil)
                }
                Button { onOpenMail(conversation.id) } label: {
                    MailConversationRow(
                        conversation: conversation,
                        isSelected: false,
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
                .buttonStyle(.plain)
                Divider().padding(.leading, 21)
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
            if showsMail, let unread = folderUnread, unread > 0 {
                Text("\(unread)")
                    .font(.system(size: 10, weight: .semibold))
                    .monospacedDigit()
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                    .foregroundStyle(Color.accentColor)
                    .help(localization.tr("popover.inbox.unreadHelp", folderTitle, unread))
            }
            Spacer(minLength: 4)
            if showsMail {
                Button {
                    onOpenMail(nil)
                } label: {
                    HStack(spacing: 3) {
                        Text(localization.tr("mail.popover.open"))
                        Image(systemName: "arrow.right").font(.system(size: 9, weight: .semibold))
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
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
        .buttonStyle(.plain)
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
        .buttonStyle(.plain)
        .padding(.horizontal, horizontalPadding - 6)
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
