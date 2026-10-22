import SwiftUI

/// What needs the user's attention, from data the window already has (no extra requests).
struct MailDigest: Equatable {
    var unreadFromPeople: [MailConversationSummary]
    /// Folders other than the inbox with unread mail: mostly rule folders of systems.
    var busyFolders: [MailFolder]

    var isEmpty: Bool { unreadFromPeople.isEmpty && busyFolders.isEmpty }

    static let limit = 6

    static func build(peopleUnread: [MailConversationSummary], folders: [MailFolder]) -> MailDigest {
        let skipped: Set<MailDistinguishedFolder> = [.inbox, .drafts, .sentitems, .deleteditems, .junkemail, .outbox]
        let busy = MailSidebarPolicy.visibleFolders(folders)
            .filter { $0.unreadCount > 0 && !($0.distinguished.map(skipped.contains) ?? false) }
            .sorted { $0.unreadCount > $1.unreadCount }
        return MailDigest(
            unreadFromPeople: Array(peopleUnread.prefix(limit)),
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
        MailDigest.build(peopleUnread: service.peopleUnread, folders: model.folders)
    }

    var body: some View {
        let digest = digest
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if digest.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "checkmark.circle").font(.app(.symbol)).foregroundStyle(.tertiary)
                        Text(localization.tr("mail.digest.allClear")).font(.app(.headline)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
                }
                if !digest.unreadFromPeople.isEmpty {
                    section(localization.tr("mail.digest.unread"), count: service.peopleUnread.count, icon: "envelope.badge") {
                        ForEach(digest.unreadFromPeople) { conversationRow($0) }
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
                                    .font(.app(.body))
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 4)
                                    .background(Capsule().fill(Color.secondary.opacity(0.12)))
                                }
                                .buttonStyle(.mailRow(cornerRadius: 12))
                            }
                        }
                    }
                }
                Text(localization.tr("mail.reading.shortcuts"))
                    .font(.app(.footnote))
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
                Image(systemName: icon).font(.app(.footnote)).foregroundStyle(.secondary)
                Text(title).font(.app(.body, weight: .semibold)).foregroundStyle(.secondary)
                if let count { Text("\(count)").font(.app(.footnote)).monospacedDigit().foregroundStyle(.tertiary) }
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
}
