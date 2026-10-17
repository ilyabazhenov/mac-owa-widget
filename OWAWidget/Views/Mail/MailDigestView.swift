import SwiftUI

/// What needs the user's attention, from data the window already has (no extra requests).
struct MailDigest: Equatable {
    var unreadFromPeople: [MailConversationSummary]
    var awaitingReply: [MailConversationSummary]
    /// Folders other than the inbox with unread mail: mostly rule folders of systems.
    var busyFolders: [MailFolder]

    var isEmpty: Bool { unreadFromPeople.isEmpty && awaitingReply.isEmpty && busyFolders.isEmpty }

    static let limit = 6
    static let awaitingDays = 7

    /// People's recent conversations the user has not written in (and that are not already listed
    /// as unread): a heuristic, as in the MCP digest.
    static func awaitingReply(in list: [MailConversationSummary], excluding ids: Set<String>, now: Date = Date()) -> [MailConversationSummary] {
        let since = now.addingTimeInterval(-Double(awaitingDays) * 86_400)
        return list.filter {
            !$0.isAutomated && !$0.userHasReplied && !$0.isMeetingRequest && !$0.isMeetingCancellation
                && ($0.lastDelivery ?? .distantPast) >= since && !ids.contains($0.id)
        }
    }

    /// - Parameters:
    ///   - inboxList: the inbox conversations the list shows, or `nil` when it shows something
    ///     else (another folder, a search): "awaiting reply" is then left out.
    static func build(
        peopleUnread: [MailConversationSummary],
        inboxList: [MailConversationSummary]?,
        folders: [MailFolder],
        now: Date = Date()
    ) -> MailDigest {
        let awaiting = awaitingReply(in: inboxList ?? [], excluding: Set(peopleUnread.map(\.id)), now: now)
        let skipped: Set<MailDistinguishedFolder> = [.inbox, .drafts, .sentitems, .deleteditems, .junkemail, .outbox]
        let busy = MailSidebarPolicy.visibleFolders(folders)
            .filter { $0.unreadCount > 0 && !($0.distinguished.map(skipped.contains) ?? false) }
            .sorted { $0.unreadCount > $1.unreadCount }
        return MailDigest(
            unreadFromPeople: Array(peopleUnread.prefix(limit)),
            awaitingReply: Array(awaiting.prefix(limit)),
            busyFolders: Array(busy.prefix(8))
        )
    }
}

/// The reader when nothing is open: a short digest instead of an empty page.
struct MailDigestView: View {
    @ObservedObject var model: MailWindowModel
    @ObservedObject var service: MailService
    @EnvironmentObject private var localization: LocalizationService

    private var digest: MailDigest {
        let showsInbox = model.selectedFolder == .distinguished(.inbox) && !model.isSearching
        return MailDigest.build(
            peopleUnread: service.peopleUnread,
            inboxList: showsInbox ? model.conversations : nil,
            folders: model.folders
        )
    }

    var body: some View {
        let digest = digest
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if digest.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "checkmark.circle").font(.system(size: 26)).foregroundStyle(.tertiary)
                        Text(localization.tr("mail.digest.allClear")).font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
                }
                if !digest.unreadFromPeople.isEmpty {
                    section(localization.tr("mail.digest.unread"), count: service.peopleUnread.count, icon: "envelope.badge") {
                        ForEach(digest.unreadFromPeople) { conversationRow($0) }
                    }
                }
                if !digest.awaitingReply.isEmpty {
                    section(localization.tr("mail.digest.awaiting"), count: nil, icon: "arrowshape.turn.up.left") {
                        ForEach(digest.awaitingReply) { conversationRow($0) }
                    }
                }
                if !digest.busyFolders.isEmpty {
                    section(localization.tr("mail.digest.folders"), count: nil, icon: "folder") {
                        FlowRow(spacing: 6) {
                            ForEach(digest.busyFolders) { folder in
                                Button { model.select(folder: folder) } label: {
                                    HStack(spacing: 5) {
                                        Text(folder.displayName).lineLimit(1)
                                        Text("\(folder.unreadCount)").monospacedDigit().foregroundStyle(Color.accentColor)
                                    }
                                    .font(.system(size: 12))
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 4)
                                    .background(Capsule().fill(Color.secondary.opacity(0.12)))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                Text(localization.tr("mail.reading.shortcuts"))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 6)
            }
            .frame(maxWidth: 560, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
        }
    }

    private func section<Content: View>(_ title: String, count: Int?, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11)).foregroundStyle(.secondary)
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                if let count { Text("\(count)").font(.system(size: 11)).monospacedDigit().foregroundStyle(.tertiary) }
            }
            content()
        }
    }

    private func conversationRow(_ conversation: MailConversationSummary) -> some View {
        Button {
            model.click(conversation, modifiers: [])
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                HStack(spacing: 4) {
                    Text(conversation.primarySender)
                        .font(.system(size: 12, weight: conversation.isUnread ? .semibold : .regular))
                        .lineLimit(1)
                    if service.isExternalSender(conversation) { MailExternalTag() }
                }
                .frame(width: 170, alignment: .leading)
                Text(conversation.topic.isEmpty ? localization.tr("mail.noSubject") : conversation.topic)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(MailPresentation.listTime(conversation.lastDelivery, localization: localization))
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .fixedSize()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.secondary.opacity(0.07)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
