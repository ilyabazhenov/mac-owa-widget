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

    /// How close a meeting is, for the badge on today's invitations.
    enum Soon: Equatable {
        case inProgress
        case inMinutes(Int)
    }

    /// `nil` unless the meeting is today and not over: a date further off is said by the day
    /// badge alone.
    static func soon(_ event: CalendarEvent, now: Date, calendar: Calendar = AppTimeZone.calendar) -> Soon? {
        guard calendar.isDate(event.startDate, inSameDayAs: now), event.endDate > now else { return nil }
        if event.startDate <= now { return .inProgress }
        return .inMinutes(Int((event.startDate.timeIntervalSince(now) / 60).rounded(.up)))
    }

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

        // A cancellation sent with high importance is a calendar notice, not something important
        // to read: left out, unless the user flagged it themselves.
        let important = known
            .filter { $0.isFlagged || ($0.importance == .high && !$0.isMeetingCancellation) }
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
/// a title, counts on top, then what waits for an answer, what is important and the folders with
/// unread mail, and the keys at the bottom.
///
/// Colour carries meaning only: orange for what needs the user (invitations, today's meeting),
/// green for the answer most give (Accept), red and orange for importance and flags, the accent
/// for counts. Everything else stays grey.
struct MailDigestView: View {
    @ObservedObject var model: MailWindowModel
    @ObservedObject var service: MailService
    @EnvironmentObject private var calendar: CalendarService
    @EnvironmentObject private var localization: LocalizationService
    /// Invitations with an answer on its way, so a second click cannot send another.
    @State private var responding: Set<String> = []
    @State private var failed: Set<String> = []
    /// The answer whose confirmation is open, if any.
    @State private var confirming: PendingAnswer?

    private struct PendingAnswer: Equatable {
        let eventID: String
        let action: MeetingResponseAction
    }

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
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 12) {
                        header
                        MailDigestDayLoadView()
                        MailDigestNextMeetingView()
                    }
                    tiles(digest, proxy: proxy)
                    if digest.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "checkmark.circle").font(.app(.symbol)).foregroundStyle(.green)
                            Text(localization.tr("mail.digest.allClear")).font(.app(.headline)).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                    }
                    if !digest.invitations.isEmpty {
                        section(localization.tr("mail.digest.invitations"), count: digest.invitations.count, icon: "calendar.badge.exclamationmark", tint: .orange, countIsUrgent: true) {
                            ForEach(digest.invitations) { invitationRow($0) }
                        }
                        .id(Anchor.invitations)
                    }
                    if !digest.unreadFromPeople.isEmpty {
                        section(localization.tr("mail.digest.unread"), count: service.peopleUnread.count, icon: "person.2", tint: .teal) {
                            ForEach(digest.unreadFromPeople) { conversationRow($0) }
                        }
                        .id(Anchor.people)
                    }
                    MailDigestColleaguesView()
                    // Side by side while there is room, one under the other in a narrow reader.
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 22) {
                            importantSection(digest).frame(minWidth: 240, maxWidth: .infinity, alignment: .topLeading)
                            foldersSection(digest).frame(minWidth: 240, maxWidth: .infinity, alignment: .topLeading)
                        }
                        VStack(alignment: .leading, spacing: 20) {
                            importantSection(digest)
                            foldersSection(digest)
                        }
                    }
                    keys
                }
                .frame(maxWidth: 720, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.vertical, 22)
                .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: Title

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(localization.tr("mail.overview"))
                .font(.app(.largeTitle, weight: .semibold))
            Text(subtitle)
                .font(.app(.footnote))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var subtitle: String {
        let day = localization.formatDate(Date(), format: "EEEE, d MMMM")
        var parts = [day.prefix(1).uppercased() + day.dropFirst()]
        if let checked = service.lastChecked {
            parts.append(localization.tr("mail.window.subtitle.updated", localization.shortTime(checked)))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Counts

    /// Four equal tiles across the whole width; two by two when the reader is too narrow for
    /// four labels side by side.
    private func tiles(_ digest: MailDigest, proxy: ScrollViewProxy) -> some View {
        let items: [(Int, String, String, Color, Bool, () -> Void)] = [
            (digest.inboxUnread ?? 0, "mail.digest.tile.inbox", "tray", .accentColor, false, {
                // The inbox, new mail only: what the number counts.
                if let inbox = model.folders.first(where: { $0.distinguished == .inbox }) { model.select(folder: inbox) }
                model.mode = .unread
            }),
            (digest.peopleUnreadCount, "mail.digest.tile.people", "person.2", .teal, false, { scroll(proxy, to: .people) }),
            // The one tile that asks for something: it stands out while it is not zero.
            (digest.invitations.count, "mail.digest.tile.invitations", "calendar.badge.exclamationmark", .orange, true, { scroll(proxy, to: .invitations) }),
            (digest.flaggedCount, "mail.digest.tile.flagged", "flag", .orange, false, { scroll(proxy, to: .important) }),
        ]
        let columns = { (count: Int) in Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .top), count: count) }
        return ViewThatFits(in: .horizontal) {
            LazyVGrid(columns: columns(4), spacing: 8) {
                ForEach(items.indices, id: \.self) { index in
                    let item = items[index]
                    tile(item.0, item.1, icon: item.2, tint: item.3, asksForAction: item.4, action: item.5)
                }
            }
            .frame(minWidth: 4 * 120 + 3 * 8)
            LazyVGrid(columns: columns(2), spacing: 8) {
                ForEach(items.indices, id: \.self) { index in
                    let item = items[index]
                    tile(item.0, item.1, icon: item.2, tint: item.3, asksForAction: item.4, action: item.5)
                }
            }
        }
    }

    private func tile(_ value: Int, _ key: String, icon: String, tint: Color, asksForAction: Bool, action: @escaping () -> Void) -> some View {
        let isZero = value == 0
        let highlighted = asksForAction && !isZero
        return Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(value)")
                        .font(.app(.symbol, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(isZero ? AnyShapeStyle(.tertiary) : highlighted ? AnyShapeStyle(tint) : AnyShapeStyle(.primary))
                    Spacer(minLength: 4)
                    Image(systemName: icon)
                        .font(.app(.headline))
                        .foregroundStyle(isZero ? AnyShapeStyle(.tertiary) : AnyShapeStyle(tint))
                }
                // Two lines kept for every label, so a one-line tile is as tall as its neighbours.
                Text(localization.tr(key))
                    .font(.app(.footnote))
                    .foregroundStyle(highlighted ? AnyShapeStyle(tint) : AnyShapeStyle(.secondary))
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, minHeight: 58, alignment: .topLeading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 10).fill(highlighted ? tint.opacity(0.14) : Color.secondary.opacity(0.07)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.mailRow(cornerRadius: 10))
        .disabled(isZero)
        .accessibilityElement(children: .combine)
    }

    private func scroll(_ proxy: ScrollViewProxy, to anchor: Anchor) {
        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(anchor, anchor: .top) }
    }

    // MARK: Sections

    private func section<Content: View>(
        _ title: String, count: Int?, icon: String, tint: Color, countIsUrgent: Bool = false,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            MailDigestSectionHeader(title: title, count: count, icon: icon, tint: tint, countIsUrgent: countIsUrgent)
            content()
        }
    }

    @ViewBuilder
    private func importantSection(_ digest: MailDigest) -> some View {
        if !digest.important.isEmpty {
            section(localization.tr("mail.digest.important"), count: nil, icon: "exclamationmark.circle", tint: .red) {
                ForEach(digest.important) { conversation in
                    Button { model.click(conversation, modifiers: []) } label: {
                        HStack(spacing: 8) {
                            // A flag is the user's own mark, high importance the sender's: two signs.
                            Image(systemName: conversation.isFlagged ? "flag.fill" : "exclamationmark.circle.fill")
                                .font(.app(.body))
                                .foregroundStyle(conversation.isFlagged ? Color.orange : Color.red)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(conversation.topic.isEmpty ? localization.tr("mail.noSubject") : conversation.topic.trimmingCharacters(in: .whitespacesAndNewlines))
                                    .font(.app(.body))
                                    .lineLimit(1)
                                Text([conversation.primarySender, MailPresentation.listTime(conversation.lastDelivery, localization: localization)]
                                    .filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.app(.footnote))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
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
            section(localization.tr("mail.digest.folders"), count: nil, icon: "folder", tint: .accentColor) {
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

    /// The day on the left says when at a glance: the weekday on top, the date below — or, for
    /// today's meeting, the time, in orange. The weekday rather than "today" on top, so every
    /// badge reads the same way; "today" did not fit the badge, and the colour and the
    /// "in 14 h" badge already say it.
    private func dayBadge(_ event: CalendarEvent) -> some View {
        let isToday = AppTimeZone.calendar.isDateInToday(event.startDate)
        return VStack(spacing: 0) {
            Text(localization.formatDate(event.startDate, format: "EE"))
                .font(.app(.micro, weight: .medium))
                .textCase(.uppercase)
            Text(isToday ? localization.shortTime(event.startDate) : localization.formatDate(event.startDate, format: "d"))
                .font(.app(isToday ? .footnote : .title, weight: .semibold))
                .monospacedDigit()
        }
        .foregroundStyle(isToday ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.primary))
        .frame(width: 46, height: 36)
        .background(RoundedRectangle(cornerRadius: 7).fill(isToday ? Color.orange.opacity(0.14) : Color.secondary.opacity(0.08)))
        .accessibilityHidden(true)
    }

    private func invitationRow(_ invitation: MailDigest.Invitation) -> some View {
        let event = invitation.event
        let isResponding = responding.contains(event.id)
        let day = localization.formatDate(event.startDate, format: "EE, d MMM")
        let time = "\(localization.shortTime(event.startDate))–\(localization.shortTime(event.endDate))"
        return HStack(spacing: 12) {
            dayBadge(event)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    // Titles come as typed by the organizer, leading spaces included.
                    Text(event.title.trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(.app(.body, weight: .semibold))
                        .lineLimit(1)
                    if let soon = MailDigest.soon(event, now: Date()) { soonBadge(soon) }
                }
                Text([event.organizer, AppTimeZone.calendar.isDateInToday(event.startDate) ? time : "\(day), \(time)"]
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
                // All three answers as small icons, each asking first: the answer goes to the
                // organizer, and five similar rows make a click on the wrong one easy.
                HStack(spacing: 6) {
                    answerButton(event, .accept)
                    answerButton(event, .tentative)
                    answerButton(event, .decline)
                }
                Button { open(invitation) } label: {
                    Image(systemName: "arrow.up.right.square")
                        .font(.app(.headline))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(localization.tr("mail.digest.openMail"))
                .accessibilityLabel(localization.tr("mail.digest.openMail"))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.07)))
    }

    private struct AnswerStyle {
        let icon: String
        let tint: Color
        let labelKey: String
        let confirmKey: String
    }

    private func style(_ action: MeetingResponseAction) -> AnswerStyle {
        switch action {
        case .accept: AnswerStyle(icon: "checkmark", tint: .green, labelKey: "meeting.rsvp.accept", confirmKey: "mail.digest.confirm.accept")
        case .tentative: AnswerStyle(icon: "questionmark", tint: .orange, labelKey: "meeting.rsvp.tentative", confirmKey: "mail.digest.confirm.tentative")
        case .decline: AnswerStyle(icon: "xmark", tint: .red, labelKey: "meeting.rsvp.decline", confirmKey: "mail.digest.confirm.decline")
        }
    }

    private func answerButton(_ event: CalendarEvent, _ action: MeetingResponseAction) -> some View {
        let style = style(action)
        let pending = PendingAnswer(eventID: event.id, action: action)
        return Button { confirming = pending } label: {
            Image(systemName: style.icon)
                .font(.app(.footnote, weight: .bold))
                .foregroundStyle(style.tint)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7).fill(style.tint.opacity(0.15)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(localization.tr(style.labelKey))
        .accessibilityLabel(localization.tr(style.labelKey))
        .popover(isPresented: Binding(
            get: { confirming == pending },
            set: { if !$0, confirming == pending { confirming = nil } }
        ), arrowEdge: .bottom) {
            confirmation(event, action, style: style)
        }
    }

    /// Says exactly what is being answered — the meeting's name and time — before anything is
    /// sent; Return confirms, Esc cancels.
    private func confirmation(_ event: CalendarEvent, _ action: MeetingResponseAction, style: AnswerStyle) -> some View {
        let title = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let day = localization.formatDate(event.startDate, format: "EE, d MMM")
        let time = "\(localization.shortTime(event.startDate))–\(localization.shortTime(event.endDate))"
        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(question(style.confirmKey, title: title))
                    .font(.app(.body, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(day), \(time). " + localization.tr("mail.digest.confirm.hint"))
                    .font(.app(.footnote))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                // "Отмена", not "Отменить": next to "Отклонить" the latter reads as cancelling
                // the meeting.
                Button(localization.tr("mail.digest.confirm.cancel")) { confirming = nil }
                    .keyboardShortcut(.cancelAction)
                Button(localization.tr(style.labelKey), role: action == .decline ? .destructive : nil) {
                    confirming = nil
                    respond(event, action)
                }
                .keyboardShortcut(.defaultAction)
                .tint(style.tint)
            }
        }
        .padding(14)
        .frame(width: 300)
    }

    /// "Accept “Shall we?”?" reads badly: a title that already ends in a question mark keeps
    /// it, and the sentence's own is dropped.
    private func question(_ key: String, title: String) -> String {
        let text = localization.tr(key, title)
        return title.hasSuffix("?") && text.hasSuffix("?") ? String(text.dropLast()) : text
    }

    private func soonBadge(_ soon: MailDigest.Soon) -> some View {
        let text: String = switch soon {
        case .inProgress: localization.tr("mail.digest.inProgress")
        // Whole hours past the first: "in 14 h", not "in 14 h 28 min" — a badge, not a clock.
        case .inMinutes(let minutes): localization.tr("mail.digest.inTime", localization.compactDuration(minutes: minutes >= 60 ? minutes / 60 * 60 : minutes))
        }
        return Text(text)
            .font(.app(.micro, weight: .semibold))
            .foregroundStyle(.orange)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.orange.opacity(0.16)))
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

    private static let keyItems: [(keys: String, labelKey: String)] = [
        ("↑↓", "mail.key.navigate"), ("R", "mail.key.reply"), ("⇧R", "mail.key.replyAll"),
        ("F", "mail.key.forward"), ("U", "mail.key.read"), ("⌫", "mail.key.delete"),
        ("⌘", "mail.key.multiSelect"), ("Esc", "mail.key.overview"), ("⌃⌥M", "mail.key.window"),
    ]

    /// Reference, not content: small and quiet, under a rule at the bottom.
    private var keys: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider().padding(.bottom, 10)
            FlowRow(spacing: 14) {
                ForEach(Self.keyItems, id: \.labelKey) { item in
                    HStack(spacing: 4) {
                        Text(item.keys)
                            .font(.app(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.secondary.opacity(0.35)))
                        Text(localization.tr(item.labelKey))
                            .font(.app(.caption))
                            .foregroundStyle(.tertiary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .padding(.top, 4)
    }
}
