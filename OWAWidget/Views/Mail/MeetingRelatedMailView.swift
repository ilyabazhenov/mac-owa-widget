import SwiftUI

/// "Mail about this meeting" in the meeting card: conversations with its subject and recent mail
/// from its people. Loaded only when asked for — two searches per meeting are not free.
struct MeetingRelatedMailView: View {
    @ObservedObject var mail: MailService
    let event: CalendarEvent
    let attendees: [EventAttendee]

    @EnvironmentObject private var localization: LocalizationService
    @State private var state: LoadState = .idle

    enum LoadState: Equatable {
        case idle
        case loading
        case loaded([MailConversationSummary])
        case failed
    }

    /// Up to three other people: the user's own address and the meeting's rooms add nothing.
    private var people: [String] {
        let own = mail.ownAddress?.lowercased()
        return attendees.compactMap(\.email)
            .filter { $0.lowercased() != own && !$0.lowercased().hasPrefix("room") }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch state {
            case .idle:
                Button {
                    load()
                } label: {
                    Label(localization.tr("mail.related.show"), systemImage: "tray.full")
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderless)
            case .loading:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(localization.tr("mail.related.loading")).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            case .failed:
                Button(localization.tr("mail.related.failed")) { load() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 12))
            case .loaded(let conversations):
                Label(localization.tr("mail.related.title"), systemImage: "tray.full")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                if conversations.isEmpty {
                    Text(localization.tr("mail.related.empty")).font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    ForEach(conversations) { conversation in
                        Button {
                            mail.open(conversationID: conversation.id)
                        } label: {
                            HStack(spacing: 6) {
                                HStack(spacing: 4) {
                                    Text(conversation.primarySender)
                                        .font(.system(size: 11, weight: conversation.isUnread ? .semibold : .medium))
                                        .lineLimit(1)
                                    if mail.isExternalSender(conversation) { MailExternalTag() }
                                }
                                .frame(maxWidth: 150, alignment: .leading)
                                Text(conversation.topic)
                                    .font(.system(size: 11))
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                Text(MailPresentation.listTime(conversation.lastDelivery, localization: localization))
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .fixedSize()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(conversation.preview)
                    }
                }
            }
        }
        .padding(.leading, 2)
        .onChange(of: event.id) { _ in state = .idle }
    }

    private func load() {
        state = .loading
        let title = event.title
        let people = people
        Task {
            do {
                let found = try await mail.relatedMail(title: title, people: people)
                state = .loaded(found)
            } catch {
                state = MailCancellation.isCancellation(error) ? .idle : .failed
            }
        }
    }
}
