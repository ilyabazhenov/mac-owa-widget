import AppKit
import SwiftUI

/// The message the inbox panel shows in place of its list. Owned by the popover, which closes it
/// on Esc and when it closes itself; the panel only draws it.
///
/// The reader is a `MailWindowModel` of its own, made when a message opens and dropped when the
/// panel goes back to its list: it brings the window's reading as it is (bodies, inline images,
/// read marking, meeting answers), and what it holds goes with it.
@MainActor
final class InboxPanelReader: ObservableObject {
    @Published private(set) var conversationID: String?
    @Published private(set) var model: MailWindowModel?
    /// The last message read, kept after going back so the list can mark and scroll to it; it is
    /// forgotten when the popover closes.
    @Published private(set) var lastOpenedID: String?
    private weak var service: MailService?

    var isOpen: Bool { conversationID != nil }

    func open(_ conversationID: String, in folder: MailFolderRef, service: MailService) {
        let model: MailWindowModel
        if let current = self.model {
            model = current
        } else {
            model = MailWindowModel(service: service)
            self.model = model
            self.service = service
            service.panelReaderDidAppear()
            // As the mail window does: the network block (normally ready since the panel showed)
            // and WebKit's processes, so the first body does not wait for them.
            MailContentBlocker.prepare()
            MailReaderWebKit.prewarm()
        }
        // The folder tree the panel already has: no request, and read marks move its counts.
        model.adopt(folders: service.folders)
        model.selectedFolder = folder
        self.conversationID = conversationID
        lastOpenedID = conversationID
        DiagnosticLog.event("Inbox panel reader opened")
        Task { await model.openConversation(conversationID) }
    }

    /// Back to the list. `forget` also drops the mark on the row last read (the popover closed).
    func close(forget: Bool = false) {
        if forget { lastOpenedID = nil }
        guard model != nil || conversationID != nil else { return }
        conversationID = nil
        model = nil
        service?.panelReaderDidDisappear()
        // The window keeps its own warm view while it is open.
        if service?.isWindowOpen != true { MailReaderWebKit.release() }
        DiagnosticLog.event("Inbox panel reader closed")
    }

    /// Opens the conversation `step` rows away in the panel's list (−1 above, +1 below).
    /// Returns whether there was one.
    @discardableResult
    func step(_ step: Int, service: MailService) -> Bool {
        guard let next = Self.neighbor(of: conversationID, step: step, in: service.panelList.map(\.id)) else { return false }
        open(next, in: service.panelFolder, service: service)
        return true
    }

    func canStep(_ step: Int, in list: [MailConversationSummary]) -> Bool {
        Self.neighbor(of: conversationID, step: step, in: list.map(\.id)) != nil
    }

    /// The id `step` places from `id` in `list`; `nil` past either end, or when `id` has left
    /// the list (a refresh dropped it), since there is then no "next" to speak of.
    nonisolated static func neighbor(of id: String?, step: Int, in list: [String]) -> String? {
        guard let id, let index = list.firstIndex(of: id) else { return nil }
        let target = index + step
        return list.indices.contains(target) ? list[target] : nil
    }
}

/// A message in the inbox panel: the thread's subject, its messages as the mail window shows
/// them, and the everyday actions under them.
struct PopoverMailReaderView: View {
    @ObservedObject var model: MailWindowModel
    @ObservedObject var mail: MailService
    /// The row that was clicked: subject and senders while the thread is on its way.
    let summary: MailConversationSummary?
    let horizontalPadding: CGFloat
    /// Off in Deleted Items, and once the row has left the list.
    let canDelete: Bool
    let onDelete: () -> Void
    /// Opens the compose window on the request already handed to the service.
    let onShowCompose: () -> Void
    let onOpenInWindow: () -> Void

    @EnvironmentObject private var localization: LocalizationService

    private var newest: MailMessage? { model.thread?.messages.first }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    subject
                    content
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)
            if let link = model.pendingLink {
                Divider()
                linkPrompt(link)
            }
            if let error = model.actionError {
                Divider()
                errorLine(error)
            }
            if let message = newest {
                Divider()
                actionBar(message)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: model.pendingLink?.url)
    }

    // MARK: - Pieces

    private var subject: some View {
        let topic = summary?.topic ?? model.thread?.topic ?? ""
        return Text(topic.isEmpty ? localization.tr("mail.noSubject") : topic)
            .font(.system(size: 15, weight: .semibold))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var content: some View {
        if let thread = model.thread {
            ForEach(thread.messages) { message in
                MailMessageCard(model: model, service: mail, message: message, stacksAttachments: true)
            }
            if thread.totalMessageCount > thread.messages.count {
                Label(localization.tr("mail.thread.more", thread.totalMessageCount - thread.messages.count), systemImage: "ellipsis.bubble")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if let error = model.threadError, !model.isLoadingThread {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(localization.tr("mail.retry")) { retry() }
                    Button(localization.tr("popover.inbox.openWindow")) { onOpenInWindow() }
                }
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 24)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                if let senders = summary?.senders, !senders.isEmpty {
                    Text(senders.joined(separator: ", "))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(localization.tr("mail.reading.loading"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 24)
            }
        }
    }

    private func retry() {
        guard let id = model.selectedConversationID else { return }
        Task { await model.openConversation(id, reload: true) }
    }

    /// Reply first and labelled; the rest as icons, so the row fits the panel.
    private func actionBar(_ message: MailMessage) -> some View {
        HStack(spacing: 2) {
            Button { reply(.reply, message) } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrowshape.turn.up.left").font(.system(size: 13))
                    Text(localization.tr("mail.action.reply")).font(.system(size: 12))
                }
                .frame(height: 16)
                .lineLimit(1)
                .fixedSize()
            }
            .buttonStyle(MailIconButtonStyle(horizontalPadding: 6))
            .disabled(!(message.actions.contains(.reply) || message.actions.isEmpty))
            .help(localization.tr("mail.action.reply"))
            iconButton("arrowshape.turn.up.left.2", "mail.action.replyAll", enabled: message.actions.contains(.replyAll) || message.actions.isEmpty) {
                reply(.replyAll, message)
            }
            iconButton("arrowshape.turn.up.right", "mail.action.forward", enabled: message.actions.contains(.forward) || message.actions.isEmpty) {
                reply(.forward, message)
            }
            Spacer(minLength: 8)
            iconButton(message.isRead ? "envelope.badge" : "envelope.open", message.isRead ? "mail.action.markUnread" : "mail.action.markRead") {
                Task { await model.setRead(message, !message.isRead) }
            }
            iconButton("trash", "mail.action.delete", enabled: canDelete, action: onDelete)
        }
        .padding(.horizontal, horizontalPadding - 6)
        .padding(.vertical, 6)
    }

    private func iconButton(_ icon: String, _ key: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) { MailActionIcon(icon) }
            .buttonStyle(MailIconButtonStyle(horizontalPadding: 4))
            .disabled(!enabled)
            .help(localization.tr(key))
            .accessibilityLabel(localization.tr(key))
    }

    private func reply(_ kind: MailOutgoing.Kind, _ message: MailMessage) {
        model.compose(kind, from: message, ownAddress: mail.ownAddress)
        onShowCompose()
    }

    /// The mail window asks in a dialog; a sheet on this panel, which never takes focus, would
    /// not behave, so the same question sits under the message.
    private func linkPrompt(_ link: MailLinkActivation) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(localization.tr("mail.link.title"))
                .font(.system(size: 12, weight: .semibold))
            Text(link.explanation(localization))
                .foregroundStyle(link.mismatchedHost == nil ? Color.secondary : Color.orange)
                .font(.system(size: 11))
                .lineLimit(4)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Button(localization.tr("mail.link.open")) {
                    model.pendingLink = nil
                    link.open(service: mail, showCompose: onShowCompose)
                }
                Button(localization.tr("mail.link.copy")) {
                    link.copy()
                    model.pendingLink = nil
                }
                Spacer(minLength: 0)
                Button(localization.tr("mail.cancel")) { model.pendingLink = nil }
            }
            .controlSize(.small)
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func errorLine(_ error: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            Text(error)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button { model.actionError = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(MailIconButtonStyle(horizontalPadding: 3))
                .help(localization.tr("mail.cancel"))
        }
        .font(.system(size: 11))
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, 6)
    }
}
