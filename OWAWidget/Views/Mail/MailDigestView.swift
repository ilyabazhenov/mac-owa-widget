import SwiftUI

/// What needs the user's attention, from data the window already has (no extra requests).
struct MailDigest: Equatable {
    /// A meeting invitation that came by mail and still waits for an answer.
    struct Invitation: Equatable, Identifiable {
        let event: CalendarEvent
        /// The invitation email, opened by "Open".
        let conversationID: String
        var id: String { event.id }
    }

    /// The inbox's unread count, from the folder list.
    var inboxUnread: Int?
    var peopleUnreadCount: Int
    var unreadFromPeople: [MailConversationSummary]
    var invitations: [Invitation]
    /// Flagged or high-importance mail among what the window has loaded.
    var important: [MailConversationSummary]
    var flaggedCount: Int
    /// Folders other than the inbox with unread mail: mostly rule folders of systems.
    var busyFolders: [MailFolder]

    var isEmpty: Bool { unreadFromPeople.isEmpty && busyFolders.isEmpty && invitations.isEmpty && important.isEmpty }

    static let limit = 6

    /// Invitations come from invitation emails at hand, matched to the meeting they create — not
    /// from every meeting without an answer: many calendars carry dozens of unanswered recurring
    /// and forwarded meetings, and a list of those would never be empty. Only meetings the user
    /// can still answer count: not theirs, not over, not cancelled, with an Exchange change key.
    static func build(
        peopleUnread: [MailConversationSummary],
        folders: [MailFolder],
        conversations: [MailConversationSummary] = [],
        events: [CalendarEvent] = [],
        now: Date = Date()
    ) -> MailDigest {
        let skipped: Set<MailDistinguishedFolder> = [.inbox, .drafts, .sentitems, .deleteditems, .junkemail, .outbox]
        let busy = MailSidebarPolicy.visibleFolders(folders)
            .filter { $0.unreadCount > 0 && !($0.distinguished.map(skipped.contains) ?? false) }
            .sorted { $0.unreadCount > $1.unreadCount }

        var seen = Set<String>()
        let known = (peopleUnread + conversations).filter { seen.insert($0.id).inserted }

        let answerable = events.filter {
            !$0.isOrganizer && $0.responseType == .notResponded && $0.changeKey != nil
                && !$0.isEffectivelyCancelled && !$0.isAllDay && $0.endDate > now
        }
        var invitations: [Invitation] = []
        for conversation in known where conversation.isMeetingRequest {
            let titles = Set([conversation.topic, MailPresentation.strippingMeetingPrefix(conversation.topic)]
                .map(MailVIP.normalized).filter { !$0.isEmpty })
            guard let event = answerable
                .filter({ titles.contains(MailVIP.normalized($0.title)) })
                .min(by: { $0.startDate < $1.startDate }),
                !invitations.contains(where: { $0.event.id == event.id })
            else { continue }
            invitations.append(Invitation(event: event, conversationID: conversation.id))
        }
        invitations.sort { $0.event.startDate < $1.event.startDate }

        let important = known
            .filter { $0.isFlagged || $0.importance == .high }
            .sorted { ($0.lastDelivery ?? .distantPast) > ($1.lastDelivery ?? .distantPast) }

        return MailDigest(
            inboxUnread: folders.first { $0.distinguished == .inbox }?.unreadCount,
            peopleUnreadCount: peopleUnread.count,
            unreadFromPeople: Array(peopleUnread.prefix(limit)),
            invitations: Array(invitations.prefix(5)),
            important: Array(important.prefix(5)),
            flaggedCount: known.filter(\.isFlagged).count,
            busyFolders: Array(busy.prefix(8))
        )
    }
}

/// The reader when nothing is open: an overview of the mailbox instead of an empty page —
/// counts on top, then what waits for an answer, mail from people, what is flagged and the
/// folders with unread mail, and the keys at the bottom.
struct MailDigestView: View {
    @ObservedObject var model: MailWindowModel
    @ObservedObject var service: MailService
    @EnvironmentObject private var calendar: CalendarService
    @EnvironmentObject private var localization: LocalizationService
    /// Invitations with an answer on its way, so a second click cannot send another.
    @State private var responding: Set<String> = []
    @State private var failed: Set<String> = []

    private enum Anchor: Hashable { case invitations, people, important }

    private var digest: MailDigest {
        MailDigest.build(
            peopleUnread: service.peopleUnread,
            folders: model.folders,
            conversations: model.conversations,
            events: calendar.events
        )
    }

    var body: some View {
        let digest = digest
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    tiles(digest, proxy: proxy)
                    if digest.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "checkmark.circle").font(.app(.symbol)).foregroundStyle(.tertiary)
                            Text(localization.tr("mail.digest.allClear")).font(.app(.headline)).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                    }
                    if !digest.invitations.isEmpty {
                        section(localization.tr("mail.digest.invitations"), count: digest.invitations.count, icon: "calendar.badge.exclamationmark") {
                            ForEach(digest.invitations) { invitationRow($0) }
                        }
                        .id(Anchor.invitations)
                    }
                    if !digest.unreadFromPeople.isEmpty {
                        section(localization.tr("mail.digest.unread"), count: service.peopleUnread.count, icon: "envelope.badge") {
                            ForEach(digest.unreadFromPeople) { conversationRow($0) }
                        }
                        .id(Anchor.people)
                    }
                    // Side by side while there is room, one under the other in a narrow reader.
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 22) {
                            importantSection(digest).frame(minWidth: 240, maxWidth: .infinity, alignment: .topLeading)
                            foldersSection(digest).frame(minWidth: 240, maxWidth: .infinity, alignment: .topLeading)
                        }
                        VStack(alignment: .leading, spacing: 18) {
                            importantSection(digest)
                            foldersSection(digest)
                        }
                    }
                    keys
                }
                .frame(maxWidth: 680, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: Counts

    /// Four equal tiles across the whole width; two by two when the reader is too narrow for
    /// four labels side by side.
    private func tiles(_ digest: MailDigest, proxy: ScrollViewProxy) -> some View {
        let items: [(Int, String, () -> Void)] = [
            (digest.inboxUnread ?? 0, "mail.digest.tile.inbox", {
                // The inbox, new mail only: what the number counts.
                if let inbox = model.folders.first(where: { $0.distinguished == .inbox }) { model.select(folder: inbox) }
                model.mode = .unread
            }),
            (digest.peopleUnreadCount, "mail.digest.tile.people", { scroll(proxy, to: .people) }),
            (digest.invitations.count, "mail.digest.tile.invitations", { scroll(proxy, to: .invitations) }),
            (digest.flaggedCount, "mail.digest.tile.flagged", { scroll(proxy, to: .important) }),
        ]
        let columns = { (count: Int) in Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .top), count: count) }
        return ViewThatFits(in: .horizontal) {
            LazyVGrid(columns: columns(4), spacing: 8) {
                ForEach(items.indices, id: \.self) { index in tile(items[index].0, items[index].1, action: items[index].2) }
            }
            .frame(minWidth: 4 * 120 + 3 * 8)
            LazyVGrid(columns: columns(2), spacing: 8) {
                ForEach(items.indices, id: \.self) { index in tile(items[index].0, items[index].1, action: items[index].2) }
            }
        }
    }

    private func tile(_ value: Int, _ key: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(value)")
                    .font(.app(.title, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(value > 0 ? .primary : .tertiary)
                // Two lines kept for every label, so a one-line tile is as tall as its neighbours
                // and the numbers sit on one line across the row.
                Text(localization.tr(key))
                    .font(.app(.footnote))
                    .foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
            }
            // One height for every tile: a reserved second line is not exactly as tall as a
            // wrapped one, and the row showed it.
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .topLeading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.07)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.mailRow(cornerRadius: 8))
        .disabled(value == 0)
        .accessibilityElement(children: .combine)
    }

    private func scroll(_ proxy: ScrollViewProxy, to anchor: Anchor) {
        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(anchor, anchor: .top) }
    }

    // MARK: Sections

    private func section<Content: View>(_ title: String, count: Int?, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.app(.footnote)).foregroundStyle(.secondary)
                Text(title).font(.app(.body, weight: .semibold)).foregroundStyle(.secondary)
                if let count { Text("\(count)").font(.app(.footnote)).monospacedDigit().foregroundStyle(.tertiary) }
            }
            content()
        }
    }

    @ViewBuilder
    private func importantSection(_ digest: MailDigest) -> some View {
        if !digest.important.isEmpty {
            section(localization.tr("mail.digest.important"), count: nil, icon: "flag") {
                ForEach(digest.important) { conversation in
                    Button { model.click(conversation, modifiers: []) } label: {
                        HStack(spacing: 6) {
                            if conversation.isFlagged {
                                Image(systemName: "flag.fill").font(.app(.caption)).foregroundStyle(.orange)
                            } else {
                                Text("!").font(.app(.body, weight: .bold)).foregroundStyle(.red)
                            }
                            Text(conversation.topic.isEmpty ? localization.tr("mail.noSubject") : conversation.topic)
                                .font(.app(.body))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Color.secondary.opacity(0.07)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.mailRow(cornerRadius: 7))
                }
            }
            .id(Anchor.important)
        }
    }

    /// One row per folder with a bar: big and small counts compare at a glance.
    @ViewBuilder
    private func foldersSection(_ digest: MailDigest) -> some View {
        if !digest.busyFolders.isEmpty {
            let largest = max(1, digest.busyFolders.map(\.unreadCount).max() ?? 1)
            section(localization.tr("mail.digest.folders"), count: nil, icon: "folder") {
                ForEach(digest.busyFolders) { folder in
                    Button { model.select(folder: folder) } label: {
                        HStack(spacing: 8) {
                            Text(folder.displayName)
                                .font(.app(.body))
                                .lineLimit(1)
                                .frame(width: 120, alignment: .leading)
                            GeometryReader { geometry in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Color.secondary.opacity(0.12))
                                    Capsule().fill(Color.accentColor.opacity(0.7))
                                        .frame(width: max(3, geometry.size.width * CGFloat(folder.unreadCount) / CGFloat(largest)))
                                }
                            }
                            .frame(height: 6)
                            Text("\(folder.unreadCount)")
                                .font(.app(.body))
                                .monospacedDigit()
                                .foregroundStyle(Color.accentColor)
                                .frame(minWidth: 32, alignment: .trailing)
                        }
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.mailRow(cornerRadius: 6))
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    // MARK: Rows

    private func invitationRow(_ invitation: MailDigest.Invitation) -> some View {
        let event = invitation.event
        let isResponding = responding.contains(event.id)
        let day = localization.formatDate(event.startDate, format: "EE, d MMM")
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title).font(.app(.body, weight: .semibold)).lineLimit(1)
                Text([event.organizer, "\(day), \(localization.shortTime(event.startDate))–\(localization.shortTime(event.endDate))"]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.app(.footnote))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if failed.contains(event.id) {
                Text(localization.tr("meeting.rsvp.error.send.failed")).font(.app(.footnote)).foregroundStyle(.red)
            }
            if isResponding {
                ProgressView().controlSize(.small)
            } else {
                // Accept is the usual answer; the other two are one click further, in the menu.
                Button(localization.tr("meeting.rsvp.accept")) { respond(event, .accept) }
                    .controlSize(.small)
                Menu {
                    Button(localization.tr("meeting.rsvp.tentative")) { respond(event, .tentative) }
                    Button(localization.tr("meeting.rsvp.decline"), role: .destructive) { respond(event, .decline) }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel(localization.tr("mail.digest.otherAnswers"))
                Button(localization.tr("invitations.action.open")) { open(invitation) }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.secondary.opacity(0.07)))
    }

    /// A real reply in Exchange, through the same path as the meeting card's buttons. The row
    /// leaves the list once the meeting is no longer unanswered.
    private func respond(_ event: CalendarEvent, _ action: MeetingResponseAction) {
        guard !responding.contains(event.id) else { return }
        responding.insert(event.id)
        failed.remove(event.id)
        Task {
            do {
                try await calendar.respondToMeeting(event, action: action)
            } catch {
                failed.insert(event.id)
            }
            responding.remove(event.id)
        }
    }

    private func open(_ invitation: MailDigest.Invitation) {
        let known = model.conversations + service.peopleUnread
        guard let conversation = known.first(where: { $0.id == invitation.conversationID }) else { return }
        model.click(conversation, modifiers: [])
    }

    private func conversationRow(_ conversation: MailConversationSummary) -> some View {
        Button {
            model.click(conversation, modifiers: [])
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                HStack(spacing: 4) {
                    Text(conversation.primarySender)
                        .font(.app(.body, weight: conversation.isUnread ? .semibold : .regular))
                        .lineLimit(1)
                    if service.isExternalSender(conversation) { MailExternalTag() }
                }
                .frame(width: 170, alignment: .leading)
                Text(conversation.topic.isEmpty ? localization.tr("mail.noSubject") : conversation.topic)
                    .font(.app(.body))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(MailPresentation.listTime(conversation.lastDelivery, localization: localization))
                    .font(.app(.footnote))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .fixedSize()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.secondary.opacity(0.07)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.mailRow(cornerRadius: 7))
    }

    // MARK: Keys

    private static let keyItems: [(keys: [String], labelKey: String)] = [
        (["↑", "↓"], "mail.key.navigate"), (["R"], "mail.key.reply"),
        (["⇧R"], "mail.key.replyAll"), (["F"], "mail.key.forward"),
        (["U"], "mail.key.read"), (["⌫"], "mail.key.delete"),
        (["⌘"], "mail.key.multiSelect"), (["Esc"], "mail.key.overview"),
        (["⌃⌥M"], "mail.key.window"),
    ]

    private var keys: some View {
        section(localization.tr("mail.digest.keys"), count: nil, icon: "keyboard") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), alignment: .leading)], alignment: .leading, spacing: 6) {
                ForEach(Self.keyItems, id: \.labelKey) { item in
                    HStack(spacing: 4) {
                        ForEach(item.keys, id: \.self) { key in
                            Text(key)
                                .font(.app(.footnote, design: .monospaced))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.secondary.opacity(0.4)))
                        }
                        Text(localization.tr(item.labelKey))
                            .font(.app(.footnote))
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .padding(.top, 6)
    }
}
