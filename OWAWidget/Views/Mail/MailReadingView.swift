import AppKit
import SwiftUI

struct MailReadingView: View {
    @ObservedObject var model: MailWindowModel
    @ObservedObject var service: MailService
    @EnvironmentObject private var localization: LocalizationService
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scrollerInset) private var scrollerInset

    var body: some View {
        Group {
            if let thread = model.thread {
                VStack(spacing: 0) {
                    actionBar(thread)
                    Divider()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            threadHeader(thread)
                            ForEach(thread.messages) { message in
                                MailMessageCard(model: model, service: service, message: message)
                            }
                            if thread.totalMessageCount > thread.messages.count {
                                Label(localization.tr("mail.thread.more", thread.totalMessageCount - thread.messages.count), systemImage: "ellipsis.bubble")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(16)
                        .padding(.trailing, scrollerInset)
                    }
                }
            } else if model.isLoadingThread {
                loadingView
            } else if let error = model.threadError {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text(error).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.selectedIDs.count > 1 {
                VStack(spacing: 8) {
                    Image(systemName: "envelope.open").font(.system(size: 28)).foregroundStyle(.tertiary)
                    Text(localization.tr("mail.reading.multiple", model.selectedIDs.count))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                MailDigestView(model: model, service: service)
            }
        }
        .confirmationDialog(
            localization.tr("mail.link.title"),
            isPresented: Binding(get: { model.pendingLink != nil }, set: { if !$0 { model.pendingLink = nil } }),
            presenting: model.pendingLink
        ) { link in
            Button(localization.tr("mail.link.open")) { open(link.url) }
            Button(localization.tr("mail.link.copy")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(link.url.absoluteString, forType: .string)
            }
            Button(localization.tr("mail.cancel"), role: .cancel) {}
        } message: { link in
            if let shown = link.text.flatMap({ MailHTMLDocument.mismatchedLinkHost(text: $0, url: link.url) }) {
                Text(localization.tr("mail.link.mismatch", shown, link.url.absoluteString))
            } else {
                Text(link.url.absoluteString)
            }
        }
    }

    /// Right after a click: the conversation's subject and sender from the list, and a spinner
    /// where the messages will be. The reader answers the click at once instead of keeping the
    /// previous view until the thread arrives.
    private var loadingView: some View {
        let summary = model.conversations.first { $0.id == model.selectedConversationID }
        return VStack(alignment: .leading, spacing: 10) {
            if let summary {
                VStack(alignment: .leading, spacing: 5) {
                    Text(summary.topic.isEmpty ? localization.tr("mail.noSubject") : summary.topic)
                        .font(.system(size: 17, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(summary.senders.joined(separator: ", "))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(localization.tr("mail.reading.loading"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, summary == nil ? 80 : 24)
            Spacer(minLength: 0)
        }
        .padding(16)
        // The action bar's height stays free, so the subject does not jump when it appears.
        .padding(.top, MailColumnWidths.headerHeight)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func open(_ url: URL) {
        switch url.scheme?.lowercased() {
        case "http", "https":
            NSWorkspace.shared.open(url)
        case "mailto":
            let address = url.absoluteString.dropFirst("mailto:".count).split(separator: "?").first.map(String.init)?.removingPercentEncoding ?? ""
            service.compose(MailComposeRequest(kind: .new, original: nil, to: address.isEmpty ? [] : [address], cc: [], subject: "", body: ""))
            openWindow(id: "mail-compose")
        default:
            break
        }
    }

    private var newest: MailMessage? { model.thread?.messages.first }

    /// Labelled buttons while they fit, icons with tooltips when the reader is narrow: a label must
    /// never wrap into "Отве / тить".
    private func actionBar(_ thread: MailThread) -> some View {
        HStack(spacing: 2) {
            if let message = newest {
                ViewThatFits(in: .horizontal) {
                    actionButtons(message, labelled: true)
                    actionButtons(message, labelled: false)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .frame(minHeight: MailColumnWidths.headerHeight)
    }

    private func actionButtons(_ message: MailMessage, labelled: Bool) -> some View {
        HStack(spacing: 2) {
            primary("arrowshape.turn.up.left", "mail.action.reply", labelled: labelled, enabled: message.actions.contains(.reply) || message.actions.isEmpty) {
                reply(.reply, message)
            }
            primary("arrowshape.turn.up.left.2", "mail.action.replyAll", labelled: labelled, enabled: message.actions.contains(.replyAll) || message.actions.isEmpty) {
                reply(.replyAll, message)
            }
            primary("arrowshape.turn.up.right", "mail.action.forward", labelled: labelled, enabled: message.actions.contains(.forward) || message.actions.isEmpty) {
                reply(.forward, message)
            }
            Divider().frame(height: 16).padding(.horizontal, 4)
            iconButton(message.isRead ? "envelope.badge" : "envelope.open", message.isRead ? "mail.action.markUnread" : "mail.action.markRead") {
                Task { await model.setRead(message, !message.isRead) }
            }
            iconButton(message.isFlagged ? "flag.slash" : "flag", message.isFlagged ? "mail.action.unflag" : "mail.action.flag") {
                Task { await model.setFlag(message, !message.isFlagged) }
            }
            categoryMenu(message)
            moveMenu
            iconButton("trash", "mail.action.delete") {
                Task { await model.moveThread(to: .distinguished(.deleteditems)) }
            }
            Spacer(minLength: 8)
            primary("arrow.up.forward.square", "mail.action.openInOWA", labelled: labelled, enabled: true) {
                model.openInOWA(message)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func categoryMenu(_ message: MailMessage) -> some View {
        Menu {
            ForEach(model.knownCategories, id: \.self) { name in
                Button {
                    Task { await model.toggleCategory(name, on: message) }
                } label: {
                    if message.categories.contains(name) { Label(name, systemImage: "checkmark") } else { Text(name) }
                }
            }
            if !message.categories.isEmpty {
                Divider()
                Button(localization.tr("mail.action.clearCategories")) { Task { await model.clearCategories(message) } }
            }
            if model.knownCategories.isEmpty {
                Text(localization.tr("mail.action.noCategories"))
            }
        } label: {
            MailActionIcon("tag")
        }
        .mailIconMenu()
        .help(localization.tr("mail.action.category"))
    }

    private var moveMenu: some View {
        Menu {
            ForEach(MailSidebarPolicy.visibleFolders(model.folders)) { folder in
                Button(folder.displayName) {
                    Task { await model.moveThread(to: folder.distinguished.map { .distinguished($0) } ?? .id(folder.id)) }
                }
            }
        } label: {
            MailActionIcon("folder")
        }
        .mailIconMenu()
        .help(localization.tr("mail.action.move"))
    }

    private func reply(_ kind: MailOutgoing.Kind, _ message: MailMessage) {
        model.compose(kind, from: message, ownAddress: service.ownAddress)
        openWindow(id: "mail-compose")
    }

    @ViewBuilder
    private func primary(_ icon: String, _ key: String, labelled: Bool, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if labelled {
                // The icon at the size of the icon-only buttons beside it, the text a step smaller.
                HStack(spacing: 4) {
                    Image(systemName: icon).font(.system(size: 13))
                    Text(localization.tr(key)).font(.system(size: 12))
                }
                .frame(height: 16)
                .lineLimit(1)
                .fixedSize()
            } else {
                MailActionIcon(icon)
            }
        }
        .buttonStyle(MailIconButtonStyle(horizontalPadding: labelled ? 6 : 4))
        .disabled(!enabled)
        .help(localization.tr(key))
        .accessibilityLabel(localization.tr(key))
    }

    private func iconButton(_ icon: String, _ key: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { MailActionIcon(icon) }
            .buttonStyle(MailIconButtonStyle(horizontalPadding: 4))
            .help(localization.tr(key))
            .accessibilityLabel(localization.tr(key))
    }

    private func threadHeader(_ thread: MailThread) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            let topic = model.conversations.first { $0.id == thread.id }?.topic ?? thread.topic
            Text(topic.isEmpty ? localization.tr("mail.noSubject") : topic)
                .font(.system(size: 17, weight: .semibold))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                let categories = Set(thread.messages.flatMap(\.categories)).sorted()
                ForEach(categories, id: \.self) { name in
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2).fill(MailPresentation.categoryColor(name)).frame(width: 8, height: 8)
                        Text(name)
                    }
                }
                Text(localization.tr("mail.thread.count", thread.totalMessageCount))
                if let folder = model.folderName(for: thread.messages.first?.parentFolderID) {
                    Text("· \(folder)")
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
    }
}

/// One message of a thread: collapsed to a line, or open with its body and attachments.
struct MailMessageCard: View {
    @ObservedObject var model: MailWindowModel
    @ObservedObject var service: MailService
    let message: MailMessage
    @EnvironmentObject private var localization: LocalizationService
    @State private var bodyHeight: CGFloat = 60

    private var isExpanded: Bool { model.expandedMessageIDs.contains(message.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .mailHover(cornerRadius: 10)
                .contentShape(Rectangle())
                .onTapGesture { model.toggleExpanded(message) }
            if isExpanded {
                content
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.18), lineWidth: 0.5))
    }

    private var initials: String {
        let name = message.from?.displayName ?? "?"
        return name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(initials)
                .font(.system(size: isExpanded ? 11 : 9, weight: .semibold))
                .frame(width: isExpanded ? 30 : 24, height: isExpanded ? 30 : 24)
                .background(Circle().fill(MailPresentation.categoryColor(message.from?.displayName ?? "").opacity(0.2)))
                .foregroundStyle(MailPresentation.categoryColor(message.from?.displayName ?? ""))
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(message.from?.displayName ?? localization.tr("mail.unknownSender"))
                        .font(.system(size: isExpanded ? 13 : 12, weight: .semibold))
                        .lineLimit(1)
                        .layoutPriority(1)
                    if isExpanded, let email = message.from?.email, email != message.from?.displayName {
                        Text(email)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    if service.isExternal(message.from?.email) { externalTag }
                    if !message.isRead { Circle().fill(Color.accentColor).frame(width: 6, height: 6) }
                    if message.isFlagged { Image(systemName: "flag.fill").font(.system(size: 9)).foregroundStyle(.orange) }
                    Spacer(minLength: 6)
                    Text(MailPresentation.messageTime(message.received, localization: localization))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                        .help(MailPresentation.fullTime(message.received, localization: localization))
                }
                if isExpanded {
                    recipients
                } else {
                    Text(message.preview)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, isExpanded ? 10 : 8)
    }

    private var externalTag: some View {
        Text(localization.tr("mail.external"))
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.orange.opacity(0.16)))
            .foregroundStyle(.orange)
            .fixedSize()
    }

    private func names(_ list: [MailAddress]) -> String {
        list.map { address in
            service.isExternal(address.email) ? "\(address.displayName) (\(address.email ?? ""))" : address.displayName
        }.joined(separator: ", ")
    }

    private var recipients: some View {
        VStack(alignment: .leading, spacing: 1) {
            if !message.to.isEmpty {
                Text(localization.tr("mail.recipients.to", names(message.to))).lineLimit(2)
            }
            if !message.cc.isEmpty {
                Text(localization.tr("mail.recipients.cc", names(message.cc))).lineLimit(2)
            }
            if !message.bcc.isEmpty {
                Text(localization.tr("mail.recipients.bcc", names(message.bcc))).lineLimit(2)
            }
            if message.hiddenRecipientCount > 0 {
                Text(localization.tr("mail.recipients.more", message.hiddenRecipientCount))
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let meeting = message.meeting {
                meetingRow(meeting)
            }
            switch message.kind {
            case .protected:
                notice("lock", localization.tr("mail.stub.protected"), action: localization.tr("mail.action.openInOWA")) { model.openInOWA(message) }
            case .archived:
                notice("archivebox", localization.tr("mail.stub.archived"), action: localization.tr("mail.action.openInOWA")) { model.openInOWA(message) }
                webBody
            default:
                webBody
            }
            let offersImages = (model.readerDocument(for: message)?.hasRemoteImages ?? false) && model.remoteImages[message.id] == nil
            let offersQuoted = model.fullBodies[message.id] == nil && message.kind.hasReadableBody && (model.thread?.messages.count ?? 0) > 1
            if offersImages || offersQuoted {
            HStack(spacing: 12) {
                if offersImages {
                    Button {
                        model.loadRemoteImages(for: message)
                    } label: {
                        pendingLabel(localization.tr("mail.images.load"), icon: "photo", isPending: model.isPending(.remoteImages(message.id)))
                    }
                    .disabled(model.isPending(.remoteImages(message.id)))
                    .help(localization.tr("mail.images.blocked"))
                }
                if offersQuoted {
                    Button {
                        Task { await model.loadFullBody(message) }
                    } label: {
                        pendingLabel(localization.tr("mail.reading.showQuoted"), icon: "text.quote", isPending: model.isPending(.fullBody(message.id)))
                    }
                    .disabled(model.isPending(.fullBody(message.id)))
                }
            }
            .buttonStyle(.mailIcon)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            }
            if !message.visibleAttachments.isEmpty {
                FlowRow(spacing: 8) {
                    ForEach(message.visibleAttachments) { attachment in
                        attachmentChip(attachment)
                    }
                }
            }
        }
    }

    /// A button label whose icon turns into a spinner while its request runs.
    private func pendingLabel(_ title: String, icon: String, isPending: Bool) -> some View {
        HStack(spacing: 4) {
            if isPending {
                ProgressView().controlSize(.mini).frame(width: 14, height: 12)
            } else {
                Image(systemName: icon).frame(width: 14, height: 12)
            }
            Text(title)
        }
    }

    @ViewBuilder
    private var webBody: some View {
        if model.fullBodies[message.id] ?? message.bodyHTML != nil {
            if let document = model.readerDocument(for: message) {
                if !document.isVisuallyEmpty { bodyView(document.html) }
            } else {
                bodyPlaceholder
            }
        } else if !message.preview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text(message.preview).font(.system(size: 13)).textSelection(.enabled)
        }
    }

    /// While the body is being prepared: as tall as a short message, so the card does not
    /// jump much when it arrives.
    private var bodyPlaceholder: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(localization.tr("mail.reading.loading")).font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 60)
    }

    private func bodyView(_ html: String) -> some View {
        MailMessageWebView(html: html, height: $bodyHeight, copyTitle: localization.tr("mail.action.copy")) { link in
            if !model.openImage(link.url, in: message) { model.pendingLink = link }
        }
        .frame(height: bodyHeight)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func meetingRow(_ meeting: MailMeetingInfo) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: message.kind == .meetingCancellation ? "calendar.badge.minus" : "calendar")
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    if let start = meeting.start {
                        let end = meeting.end.map { " – " + localization.shortTime($0) } ?? ""
                        Text(MailPresentation.fullTime(start, localization: localization) + end)
                            .font(.system(size: 12, weight: .medium))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let location = meeting.location {
                        Text(location).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                if message.kind == .meetingRequest {
                    rsvpButtons
                }
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.08)))
    }

    /// Accept / Tentative / Decline through the calendar, when the meeting is in it; the current
    /// answer is shown, and a meeting outside the synced window opens in OWA instead.
    @ViewBuilder
    private var rsvpButtons: some View {
        let current = model.meetingResponse(for: message)
        let isSending = model.isPending(.meetingResponse(message.id))
        HStack(spacing: 6) {
            rsvp(.accept, "checkmark.circle", "mail.meeting.accept", isCurrent: current == .accepted, tint: .green)
            rsvp(.tentative, "questionmark.circle", "mail.meeting.tentative", isCurrent: current == .tentative, tint: .orange)
            rsvp(.decline, "xmark.circle", "mail.meeting.decline", isCurrent: current == .declined, tint: .red)
            if isSending { ProgressView().controlSize(.small) }
        }
        .controlSize(.small)
        .disabled(isSending)
    }

    private func rsvp(_ action: MeetingResponseAction, _ icon: String, _ key: String, isCurrent: Bool, tint: Color) -> some View {
        Button {
            Task { await model.respond(to: message, action) }
        } label: {
            Label(localization.tr(key), systemImage: isCurrent ? icon + ".fill" : icon)
                .labelStyle(.titleAndIcon)
                .font(.system(size: 11, weight: isCurrent ? .semibold : .regular))
                .lineLimit(1)
                .fixedSize()
        }
        .buttonStyle(.bordered)
        .tint(isCurrent ? tint : nil)
        .help(localization.tr(key))
    }

    private func notice(_ icon: String, _ text: String, action: String, perform: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 12))
            Text(text).font(.system(size: 12))
            Button(action, action: perform).buttonStyle(.link).font(.system(size: 12))
            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }

    private func attachmentChip(_ attachment: MailAttachmentInfo) -> some View {
        HStack(spacing: 8) {
            Image(systemName: attachment.isItemAttachment ? "envelope" : "doc")
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.name).font(.system(size: 12)).lineLimit(1)
                Text(MailPresentation.byteCount(attachment.size)).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if attachment.isItemAttachment {
                Button { model.openInOWA(message) } label: { Image(systemName: "arrow.up.forward.square") }
                    .buttonStyle(.mailIcon)
                    .help(localization.tr("mail.action.openInOWA"))
            } else if model.isPending(.attachment(attachment.id)) {
                // Downloading: a preview or a save of a large file takes a few seconds.
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 52)
                    .help(localization.tr("mail.attachment.downloading"))
            } else {
                Button { Task { await model.preview(attachment) } } label: { Image(systemName: "eye") }
                    .buttonStyle(.mailIcon)
                    .help(localization.tr("mail.attachment.preview"))
                Button { Task { await model.save(attachment) } } label: { Image(systemName: "arrow.down.circle") }
                    .buttonStyle(.mailIcon)
                    .help(localization.tr("mail.attachment.save"))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1))
    }
}

/// Mail's keyboard: ↑/↓ move through the list, Return opens, ⌫ deletes, R / ⇧R / F answer,
/// U toggles read, ⌘A picks every visible conversation, Esc leaves search. Keys typed into a text
/// field (search, compose) are left alone.
struct MailKeyboardMonitor: NSViewRepresentable {
    let handle: (NSEvent) -> Bool

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.handle = handle
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.handle = handle
    }

    final class MonitorView: NSView {
        var handle: ((NSEvent) -> Bool)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                if window.firstResponder is NSText { return event }
                return self.handle?(event) == true ? nil : event
            }
        }

        // Removed in viewDidMoveToWindow when the window goes away.
    }
}

/// The mail window: folders, the list and the reader side by side.
struct MailWindowView: View {
    @ObservedObject var service: MailService
    @StateObject private var model: MailWindowModel
    @StateObject private var scrollers = ScrollerStyleObserver()
    @EnvironmentObject private var localization: LocalizationService
    @Environment(\.openWindow) private var openWindow
    @AppStorage(MailColumnWidths.sidebar.key) private var sidebarWidth: Double = 0
    @AppStorage(MailColumnWidths.list.key) private var listWidth: Double = 0
    @AppStorage(MailColumnWidths.agenda.key) private var agendaWidth: Double = 0
    @AppStorage("mailShowsAgenda") private var showsAgenda = true
    /// The calendar column needs the calendar; tests and previews may build the window without one.
    var hasCalendar = true

    init(service: MailService) {
        self.service = service
        _model = StateObject(wrappedValue: MailWindowModel(service: service))
    }

    var body: some View {
        Group {
            if !service.settings.enabled {
                placeholder("envelope.badge.shield.half.filled", localization.tr("mail.window.disabled"))
            } else if service.account == nil {
                placeholder("person.crop.circle.badge.questionmark", localization.tr("mail.window.noAccount"))
            } else {
                VStack(spacing: 0) {
                    if service.isBlocked {
                        banner(localization.tr("mail.window.blocked"), icon: "exclamationmark.lock")
                    }
                    if let error = model.actionError {
                        banner(error, icon: "exclamationmark.triangle") { model.actionError = nil }
                    }
                    if let stale = model.staleList, !service.isBlocked {
                        staleBanner(stale)
                    }
                    GeometryReader { proxy in
                        let fit = MailColumnWidths.fit(
                            total: proxy.size.width,
                            sidebar: MailColumnWidths.clamp(sidebarWidth, MailColumnWidths.sidebar),
                            list: MailColumnWidths.clamp(listWidth, MailColumnWidths.list),
                            agenda: showsAgenda && hasCalendar ? MailColumnWidths.clamp(agendaWidth, MailColumnWidths.agenda) : nil
                        )
                        HStack(spacing: 0) {
                            MailSidebarView(model: model, service: service)
                                .frame(width: fit.sidebar)
                            MailColumnDivider(width: widthBinding($sidebarWidth, MailColumnWidths.sidebar), range: MailColumnWidths.sidebar.min...MailColumnWidths.sidebar.max)
                            MailConversationListView(model: model, service: service)
                                .frame(width: fit.list)
                            MailColumnDivider(width: widthBinding($listWidth, MailColumnWidths.list), range: MailColumnWidths.list.min...MailColumnWidths.list.max)
                            MailReadingView(model: model, service: service)
                                .frame(minWidth: MailColumnWidths.readerMin, maxWidth: .infinity)
                            if let agenda = fit.agenda {
                                MailColumnDivider(width: widthBinding($agendaWidth, MailColumnWidths.agenda), range: MailColumnWidths.agenda.min...MailColumnWidths.agenda.max, resizesTrailing: true)
                                MailAgendaView(model: model, mail: service)
                                    .frame(width: agenda)
                            }
                        }
                        .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
                    }
                    .clipped()
                    .environment(\.scrollerInset, scrollers.trailingInset)
                    .background(Color(nsColor: .windowBackgroundColor))
                }
                .background(MailKeyboardMonitor(handle: handleKey))
                .searchable(text: $model.searchFilters.text, placement: .toolbar, prompt: localization.tr("mail.search.placeholder"))
                .onSubmit(of: .search) { Task { await model.submitSearch() } }
                .onChange(of: model.searchFilters.text) { text in
                    if text.isEmpty, model.isSearching {
                        model.clearSearch()
                        Task { await model.reloadList() }
                    }
                }
                .navigationTitle(windowTitle)
                .navigationSubtitle(MailPresentation.windowSubtitle(
                    unread: model.isSearching || model.selectedFolderInfo?.distinguished == .sentitems ? nil : model.selectedFolderInfo?.unreadCount,
                    lastChecked: service.lastChecked,
                    localization: localization
                ))
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        MailListOptionsMenu(model: model, service: service)
                        Button {
                            service.compose(MailComposeRequest(kind: .new, original: nil, to: [], cc: [], subject: "", body: ""))
                            openWindow(id: "mail-compose")
                        } label: {
                            Label(localization.tr("mail.action.new"), systemImage: "square.and.pencil")
                        }
                        .help(localization.tr("mail.action.new"))
                        if model.isPending(.refresh) {
                            // Same width as the button, so the toolbar does not shift.
                            ProgressView()
                                .controlSize(.small)
                                .frame(width: 28)
                                .help(localization.tr("mail.action.refresh"))
                        } else {
                            Button {
                                Task { await model.refresh() }
                            } label: {
                                Label(localization.tr("mail.action.refresh"), systemImage: "arrow.clockwise")
                            }
                            .help(localization.tr("mail.action.refresh"))
                        }
                        if hasCalendar {
                            // A toggle, not a button: the toolbar shows it pressed while the column is on.
                            Toggle(isOn: Binding(
                                get: { showsAgenda },
                                set: { value in withAnimation(.easeInOut(duration: 0.15)) { showsAgenda = value } }
                            )) {
                                Label(localization.tr("mail.agenda.toggle"), systemImage: "sidebar.right")
                            }
                            .toggleStyle(.button)
                            .help(localization.tr("mail.agenda.toggle"))
                        }
                    }
                }
                .task {
                    await service.resolveOwnAddress()
                }
                .task(id: service.account?.id) {
                    // Opened from the inbox panel: start on its folder rather than load the
                    // window's own first and switch right after.
                    await model.start(folder: service.openRequest?.folder)
                    consumeOpenRequest()
                }
                .onChange(of: service.openRequest) { _ in consumeOpenRequest() }
                .onChange(of: service.lastChecked) { _ in Task { await model.syncFolderCounts() } }
            }
        }
        .frame(minWidth: MailColumnWidths.windowMin, minHeight: 560)
        .onAppear {
            service.windowDidAppear()
            MailContentBlocker.prepare()
            MailReaderWebKit.prewarm()
        }
        .onDisappear {
            service.windowDidDisappear()
            MailAttachmentFiles.clearPreviews()
            MailReaderWebKit.release()
        }
    }

    private var windowTitle: String {
        if model.isSearching { return localization.tr("mail.search.title") }
        return model.selectedFolderInfo?.displayName ?? localization.tr("mail.folder.inbox")
    }

    /// A divider binding that starts from the shown width (0 in storage means "default").
    private func widthBinding(_ stored: Binding<Double>, _ spec: (key: String, min: Double, ideal: Double, max: Double)) -> Binding<Double> {
        Binding(
            get: { Double(MailColumnWidths.clamp(stored.wrappedValue, spec)) },
            set: { stored.wrappedValue = $0 }
        )
    }

    /// `true` when the key was handled.
    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let characters = event.charactersIgnoringModifiers?.lowercased() ?? ""
        switch event.keyCode {
        case 125: model.moveFocus(by: 1); return true // ↓
        case 126: model.moveFocus(by: -1); return true // ↑
        case 51, 117: // ⌫, ⌦
            let targets = model.actionTargets
            guard !targets.isEmpty else { return false }
            Task { await model.move(targets, to: .distinguished(.deleteditems)) }
            return true
        case 53: // Esc
            guard model.isSearching || model.selectedIDs.count > 1 else { return false }
            if model.isSearching { model.clearSearch(); Task { await model.reloadList() } } else { model.clearSelection() }
            return true
        default:
            break
        }
        if flags == .command, characters == "a" {
            model.selectAllVisible()
            return true
        }
        guard flags.subtracting(.shift).isEmpty, let message = model.thread?.messages.first else { return false }
        switch characters {
        case "r":
            model.compose(flags.contains(.shift) ? .replyAll : .reply, from: message, ownAddress: service.ownAddress)
            openWindow(id: "mail-compose")
        case "f":
            model.compose(.forward, from: message, ownAddress: service.ownAddress)
            openWindow(id: "mail-compose")
        case "u":
            Task { await model.setRead(message, !message.isRead) }
        default:
            return false
        }
        return true
    }

    private func consumeOpenRequest() {
        guard let request = service.openRequest else { return }
        service.openRequest = nil
        // Opened from the inbox panel: show the folder the panel shows, so the conversation sits
        // in its own list (and one in Deleted Items loads with that folder included).
        if let folder = request.folder { model.select(ref: folder) }
        guard !request.conversationID.isEmpty else { return }
        model.clearSearch()
        Task { await model.openConversation(request.conversationID) }
    }

    private func placeholder(_ icon: String, _ text: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 30)).foregroundStyle(.tertiary)
            Text(text).font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The list shows an earlier load: say so, how old it is, and offer to try again.
    private func staleBanner(_ notice: MailStaleListNotice) -> some View {
        HStack(spacing: 8) {
            Image(systemName: notice.isConnectionError ? "wifi.slash" : "exclamationmark.triangle").foregroundStyle(.orange)
            Text(MailPresentation.staleListText(notice, localization: localization)).font(.system(size: 12)).lineLimit(2)
            Spacer()
            Button(localization.tr("mail.retry")) { Task { await model.refresh() } }
                .controlSize(.small)
                .disabled(model.isLoadingList)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.orange.opacity(0.12))
    }

    private func banner(_ text: String, icon: String, onClose: (() -> Void)? = nil) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(.orange)
            Text(text).font(.system(size: 12)).lineLimit(2)
            Spacer()
            if let onClose {
                Button(action: onClose) { Image(systemName: "xmark") }.buttonStyle(.mailIcon)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.orange.opacity(0.12))
    }
}
