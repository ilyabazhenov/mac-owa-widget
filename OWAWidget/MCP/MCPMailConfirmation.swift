import AppKit
import SwiftUI

/// An email an MCP client asked to send, exactly as it would go out.
struct MCPMailProposal: Equatable, Sendable {
    struct Recipient: Equatable, Sendable {
        let email: String
        let isExternal: Bool
        /// Not among the original message's sender and recipients: the assistant added it.
        let isNew: Bool
    }

    struct Original: Equatable, Sendable {
        let from: String
        let subject: String
        let received: Date?
    }

    let kind: MailOutgoing.Kind
    let to: [Recipient]
    let cc: [Recipient]
    /// What the recipients see as the subject (the server's RE:/FW: form when left to it).
    let subject: String
    let body: String
    let original: Original?
    /// Names of the attachments a forward carries along.
    let forwardedAttachments: [String]
    let client: String
    let externalCheckAvailable: Bool
    /// The app's compose window is available (mail turned on), so the email can be handed to it.
    var canOpenDraft = true

    var recipients: [Recipient] { to + cc }
    var hasExternalRecipients: Bool { recipients.contains(where: \.isExternal) }
    var hasNewRecipients: Bool { kind != .new && recipients.contains(where: \.isNew) }
    var hasHiddenCharacters: Bool { [subject, body].contains(where: MCPMeetingTextPolicy.containsHiddenCharacters) }
}

@MainActor
protocol MCPMailConfirming: AnyObject {
    func confirm(_ proposal: MCPMailProposal, timeout: TimeInterval) async -> MCPConfirmationOutcome
}

@MainActor
protocol MCPMailConfirmationPresenting: AnyObject {
    func show(
        _ proposal: MCPMailProposal,
        deadline: Date,
        onConfirm: @escaping () -> Void,
        onReject: @escaping () -> Void,
        onEdit: @escaping () -> Void
    )
    func close()
}

/// Same contract as `MCPMeetingConfirmationController`: exactly one answer per request — a button,
/// the timeout or the client's cancellation — and a click on a replaced panel answers nothing.
@MainActor
final class MCPMailConfirmationController: MCPMailConfirming {
    private let presenter: MCPMailConfirmationPresenting
    private var pending: CheckedContinuation<MCPConfirmationOutcome, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var generation = 0

    init(presenter: MCPMailConfirmationPresenting? = nil) {
        self.presenter = presenter ?? MCPMailConfirmationPanel()
    }

    func confirm(_ proposal: MCPMailProposal, timeout: TimeInterval) async -> MCPConfirmationOutcome {
        finish(.cancelled)
        generation += 1
        let current = generation
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: .cancelled)
                    return
                }
                pending = continuation
                presenter.show(
                    proposal,
                    deadline: Date().addingTimeInterval(timeout),
                    onConfirm: { [weak self] in self?.finish(.confirmed, generation: current) },
                    onReject: { [weak self] in self?.finish(.rejected, generation: current) },
                    onEdit: { [weak self] in self?.finish(.handedOff, generation: current) }
                )
                timeoutTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(timeout))
                    guard !Task.isCancelled else { return }
                    self?.finish(.timedOut, generation: current)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(.cancelled, generation: current) }
        }
    }

    private func finish(_ outcome: MCPConfirmationOutcome, generation answered: Int? = nil) {
        if let answered, answered != generation { return }
        guard let continuation = pending else { return }
        pending = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        presenter.close()
        continuation.resume(returning: outcome)
        MCPDebugLog.log("prepare_mail confirmation: \(outcome)")
    }
}

@MainActor
final class MCPMailConfirmationPanel: MCPMailConfirmationPresenting {
    private var panel: NSPanel?

    func show(
        _ proposal: MCPMailProposal,
        deadline: Date,
        onConfirm: @escaping () -> Void,
        onReject: @escaping () -> Void,
        onEdit: @escaping () -> Void
    ) {
        close()
        let localization = LocalizationService()
        let view = MCPMailConfirmationView(
            proposal: proposal,
            shownAt: Date(),
            deadline: deadline,
            localization: localization,
            onConfirm: onConfirm,
            onReject: onReject,
            onEdit: onEdit
        )
        .environment(\.locale, localization.locale)
        // Hidden from screen sharing: the panel shows the whole letter.
        // Hidden from screen sharing: the panel shows the whole letter. A click while it is not
        // key only brings it forward: "Send" is never pressed by the click that refocuses it.
        self.panel = MCPFloatingPanel.present(view, width: 440, hiddenFromScreenSharing: true, firstClickActs: false)
    }

    func close() {
        panel?.close()
        panel = nil
    }
}

/// The letter in full, who gets it, and Send / Cancel / Open as Draft. Nothing reaches Exchange
/// before Send; "Open as Draft" moves the text to the app's compose window, where the user sends
/// it themselves.
struct MCPMailConfirmationView: View {
    static let visibleRecipientLimit = 8

    let proposal: MCPMailProposal
    let shownAt: Date
    let deadline: Date
    let localization: LocalizationService
    let onConfirm: () -> Void
    let onReject: () -> Void
    let onEdit: () -> Void

    @State private var armed = false
    @State private var bodyHeight: CGFloat = 0
    static let bodyBoxHeight: CGFloat = 180

    static func lineCount(_ text: String) -> Int {
        text.isEmpty ? 0 : text.split(separator: "\n", omittingEmptySubsequences: false).count
    }
    /// Seconds left before "Send" works. Every email waits: the pause is there to make the
    /// recipients and text get read, not to judge which email is risky.
    @State private var sendCountdown = Self.sendDelaySeconds

    static let sendDelaySeconds = 3

    /// "Send · 3" while counting down, "Send" once it can be pressed.
    static func sendLabel(remaining: Int, localization: LocalizationService) -> String {
        remaining > 0 ? localization.tr("mcp.mail.confirm.sendIn", remaining) : localization.tr("mcp.mail.confirm.send")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 11) {
                MCPPanelBrandBar(localization: localization) { EmptyView() }
                title
                VStack(alignment: .leading, spacing: 3) {
                    Text(proposal.subject.isEmpty ? localization.tr("mail.noSubject") : proposal.subject)
                        .font(.system(size: 15, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    if let original = proposal.original {
                        Text(localization.tr("mcp.mail.confirm.original", original.from, MailConfirmationText.date(original.received, localization: localization)))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                recipients
                if proposal.hasHiddenCharacters {
                    note(localization.tr("mcp.confirm.hiddenCharacters"), icon: "eye.trianglebadge.exclamationmark", color: .orange)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(localization.tr("mcp.mail.confirm.body"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    ScrollView {
                        Text(proposal.body.isEmpty ? " " : proposal.body)
                            .font(.system(size: 12))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .padding(8)
                            .background(GeometryReader { proxy in
                                Color.clear.preference(key: MailBodyHeightKey.self, value: proxy.size.height)
                            })
                    }
                    .frame(maxHeight: Self.bodyBoxHeight)
                    .scrollIndicators(.visible)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
                    .onPreferenceChange(MailBodyHeightKey.self) { bodyHeight = $0 }
                    // How much text there is, and a plain warning when it runs past the box: the
                    // user approves all of it, not the part in view. Characters are counted as
                    // scalars, so anything that draws nothing still adds to the count.
                    HStack(spacing: 6) {
                        Text(localization.tr("mcp.mail.confirm.size", Self.lineCount(proposal.body), proposal.body.unicodeScalars.count))
                        if bodyHeight > Self.bodyBoxHeight + 1 {
                            Label(localization.tr("mcp.mail.confirm.scroll"), systemImage: "arrow.down.circle")
                                .foregroundStyle(.orange)
                        }
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                }
                if !proposal.forwardedAttachments.isEmpty {
                    note(localization.tr("mcp.mail.confirm.attachments", proposal.forwardedAttachments.count, proposal.forwardedAttachments.joined(separator: ", ")),
                         icon: "paperclip", color: .orange)
                }
                if proposal.original != nil {
                    note(localization.tr("mcp.mail.confirm.quoted"), icon: "text.quote")
                }
            }
            .padding(16)

            TimelineView(.animation(minimumInterval: 0.25)) { context in
                let remaining = max(0, deadline.timeIntervalSince(context.date))
                let total = max(1, deadline.timeIntervalSince(shownAt))
                GeometryReader { geometry in
                    Rectangle()
                        .fill((remaining <= 10 ? Color.orange : Color.secondary).opacity(0.7))
                        .frame(width: geometry.size.width * max(0, min(1, remaining / total)))
                }
                .frame(height: 2)
                .background(Color.primary.opacity(0.08))
            }
            footer
        }
        .frame(width: 440, alignment: .leading)
        .background(WindowDragArea())
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: .windowBackgroundColor)))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke((proposal.hasExternalRecipients ? Color.orange : Color.accentColor).opacity(0.4), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        .task(id: shownAt) {
            armed = false
            sendCountdown = Self.sendDelaySeconds
            let start = ContinuousClock.now
            try? await Task.sleep(for: MCPClientApprovalView.armingDelay)
            guard !Task.isCancelled else { return }
            armed = true
            for remaining in stride(from: Self.sendDelaySeconds - 1, through: 0, by: -1) {
                try? await Task.sleep(until: start + .seconds(Self.sendDelaySeconds - remaining), clock: .continuous)
                guard !Task.isCancelled else { return }
                sendCountdown = remaining
            }
        }
    }

    private var kindKey: String {
        switch proposal.kind {
        case .new: "mcp.mail.confirm.title.new"
        case .reply: "mcp.mail.confirm.title.reply"
        case .replyAll: "mcp.mail.confirm.title.replyAll"
        case .forward: "mcp.mail.confirm.title.forward"
        }
    }

    private var title: some View {
        HStack(spacing: 8) {
            Image(systemName: proposal.kind == .forward ? "arrowshape.turn.up.right" : "paperplane")
                .font(.system(size: 14))
                .foregroundStyle(proposal.hasExternalRecipients ? Color.orange : Color.accentColor)
            Text(localization.tr(kindKey, proposal.client.isEmpty ? localization.tr("mcp.mail.confirm.unknownClient") : proposal.client))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            TimelineView(.animation(minimumInterval: 0.25)) { context in
                let remaining = max(0, deadline.timeIntervalSince(context.date))
                Text(localization.tr("mcp.confirm.countdown", Int(remaining.rounded(.up))))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(remaining <= 10 ? .orange : .secondary)
            }
            .fixedSize()
        }
    }

    private var recipients: some View {
        VStack(alignment: .leading, spacing: 4) {
            section(localization.tr("mcp.mail.confirm.to"), proposal.to)
            section(localization.tr("mcp.mail.confirm.cc"), proposal.cc)
            if !proposal.externalCheckAvailable {
                note(localization.tr("mcp.confirm.externalUnknown"), icon: "questionmark.diamond.fill", color: .orange)
            } else if proposal.hasExternalRecipients {
                note(localization.tr("mcp.mail.confirm.external"), icon: "exclamationmark.triangle.fill", color: .orange)
            }
            if proposal.hasNewRecipients {
                note(localization.tr("mcp.mail.confirm.newRecipients"), icon: "person.crop.circle.badge.plus", color: .orange)
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ people: [MCPMailProposal.Recipient]) -> some View {
        if !people.isEmpty {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            // External and new addresses always, then the rest up to the limit. Without the
            // external check nothing can be told apart, so every address is listed.
            let flagged = people.filter { $0.isExternal || $0.isNew }
            let rest = people.filter { !$0.isExternal && !$0.isNew }
            let visible = proposal.externalCheckAvailable ? flagged + rest.prefix(max(0, Self.visibleRecipientLimit - flagged.count)) : people
            ForEach(visible, id: \.email) { person in
                HStack(spacing: 6) {
                    Text(person.email)
                        .font(.system(size: 12))
                        .foregroundStyle(person.isExternal ? .orange : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(person.email)
                    if person.isExternal { tag(localization.tr("mcp.confirm.external")) }
                    if person.isNew && proposal.kind != .new { tag(localization.tr("mcp.mail.confirm.new")) }
                }
            }
            if people.count > visible.count {
                Text(localization.tr("mcp.confirm.more", people.count - visible.count)).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.orange)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.orange.opacity(0.15)))
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if proposal.canOpenDraft {
                Button(localization.tr("mcp.mail.confirm.edit"), action: onEdit)
                    .buttonStyle(.borderless)
                    .disabled(!armed)
                    .foregroundStyle(Color.accentColor)
                    .help(localization.tr("mcp.mail.confirm.edit.help"))
                    .fixedSize()
            }
            Spacer(minLength: 4)
            Button(localization.tr("mcp.confirm.reject"), action: onReject)
                .keyboardShortcut(.cancelAction)
                .fixedSize()
            // No default-action shortcut: a stray Return must not send mail.
            Button(action: onConfirm) {
                // The widest label sizes the button, so the countdown does not make it jump.
                ZStack {
                    Text(Self.sendLabel(remaining: Self.sendDelaySeconds, localization: localization)).hidden()
                    Text(Self.sendLabel(remaining: sendCountdown, localization: localization))
                }
                .monospacedDigit()
            }
                .buttonStyle(.borderedProminent)
                .tint(proposal.hasExternalRecipients || proposal.hasNewRecipients ? .orange : .accentColor)
                .disabled(sendCountdown > 0)
                .help(sendCountdown > 0 ? localization.tr("mcp.mail.confirm.wait") : "")
                .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func note(_ text: String, icon: String, color: Color = .secondary) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: icon).font(.system(size: 11)).frame(width: 12)
            Text(text).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(color)
    }
}

enum MailConfirmationText {
    @MainActor
    static func date(_ date: Date?, localization: LocalizationService) -> String {
        guard let date else { return "" }
        return localization.formatDate(date, format: "d MMMM, HH:mm")
    }
}

private struct MailBodyHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
