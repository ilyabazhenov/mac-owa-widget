import AppKit
import SwiftUI

/// The compose window's state: recipients, text, and a send that waits a few seconds so it can
/// still be undone.
@MainActor
final class MailComposeModel: ObservableObject {
    enum Phase: Equatable {
        case editing
        case countdown(Int)
        case sending
        case failed(String)
        case done(MailOutgoing.Kind, sent: Bool)
    }

    static let undoSeconds = 5

    @Published var to: [String]
    @Published var cc: [String]
    @Published var toInput = ""
    @Published var ccInput = ""
    @Published var subject: String
    @Published var body: String
    @Published private(set) var phase: Phase = .editing
    @Published private(set) var suggestions: [ResolvedAttendee] = []
    @Published var suggestionField: Field?

    enum Field { case to, cc }

    let request: MailComposeRequest
    let service: MailService
    private let defaultSubject: String
    private var countdownTask: Task<Void, Never>?
    private var suggestTask: Task<Void, Never>?

    init(request: MailComposeRequest, service: MailService) {
        self.request = request
        self.service = service
        to = request.to
        cc = request.cc
        subject = request.subject
        body = request.body
        defaultSubject = request.subject
    }

    var isLocked: Bool {
        switch phase {
        case .editing, .failed: false
        default: true
        }
    }

    var allRecipients: [String] { to + cc }

    var externalRecipients: [String] { allRecipients.filter(service.isExternal) }

    /// Domains outside the organization the message would go to, for the warning line.
    var externalDomains: [String] {
        var seen = Set<String>()
        return externalRecipients.compactMap { $0.split(separator: "@").last.map { String($0).lowercased() } }.filter { seen.insert($0).inserted }
    }

    var invalidRecipients: [String] { allRecipients.filter { !MCPCalendarTools.isEmailAddress($0) } }

    var canSend: Bool {
        !isLocked && invalidRecipients.isEmpty && !to.isEmpty
            && toInput.trimmingCharacters(in: .whitespaces).isEmpty && ccInput.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: - Recipients

    /// Turns what was typed into recipients: a list separated by commas, semicolons or spaces.
    func commit(_ field: Field) {
        let raw = field == .to ? toInput : ccInput
        let parts = raw.split(whereSeparator: { ",; \n\t".contains($0) }).map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "<>\"'")) }.filter { !$0.isEmpty }
        guard !parts.isEmpty else { return }
        for address in parts { add(address, to: field) }
        if field == .to { toInput = "" } else { ccInput = "" }
        suggestions = []
    }

    func add(_ address: String, to field: Field) {
        let all = to + cc
        guard !all.contains(where: { $0.caseInsensitiveCompare(address) == .orderedSame }) else { return }
        if field == .to { to.append(address) } else { cc.append(address) }
    }

    func remove(_ address: String) {
        to.removeAll { $0 == address }
        cc.removeAll { $0 == address }
    }

    func pick(_ person: ResolvedAttendee) {
        let field = suggestionField ?? .to
        add(person.email, to: field)
        if field == .to { toInput = "" } else { ccInput = "" }
        suggestions = []
    }

    func inputChanged(_ field: Field) {
        suggestionField = field
        let text = (field == .to ? toInput : ccInput).trimmingCharacters(in: .whitespaces)
        if text.hasSuffix(",") || text.hasSuffix(";") {
            commit(field)
            return
        }
        suggestTask?.cancel()
        guard text.count >= 2, !text.contains("@") else {
            suggestions = []
            return
        }
        suggestTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let self else { return }
            let found = await self.service.suggestRecipients(text)
            guard !Task.isCancelled else { return }
            self.suggestions = Array(found.prefix(8))
        }
    }

    // MARK: - Sending

    func outgoing(send: Bool) -> MailOutgoing {
        let trimmedSubject = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        // For a reply or a forward an untouched subject is left to Exchange, which adds RE:/FW:
        // in the mailbox's language.
        let keepServerSubject = request.kind != .new && trimmedSubject == defaultSubject
        return MailOutgoing(
            kind: request.kind,
            reference: request.original?.ref,
            to: to,
            cc: cc,
            subject: keepServerSubject ? "" : trimmedSubject,
            body: body,
            send: send
        )
    }

    /// Starts the undo countdown; the request goes to Exchange when it runs out.
    func send() {
        commit(.to)
        commit(.cc)
        guard canSend else { return }
        let outgoing = outgoing(send: true)
        countdownTask?.cancel()
        countdownTask = Task { [weak self] in
            for remaining in stride(from: Self.undoSeconds, to: 0, by: -1) {
                guard let self, !Task.isCancelled else { return }
                self.phase = .countdown(remaining)
                try? await Task.sleep(for: .seconds(1))
            }
            guard let self, !Task.isCancelled else { return }
            await self.deliver(outgoing)
        }
    }

    func undo() {
        countdownTask?.cancel()
        countdownTask = nil
        phase = .editing
    }

    func saveDraft() {
        commit(.to)
        commit(.cc)
        guard invalidRecipients.isEmpty else { return }
        Task { await deliver(outgoing(send: false)) }
    }

    private func deliver(_ outgoing: MailOutgoing) async {
        phase = .sending
        do {
            try await service.send(outgoing)
            phase = .done(outgoing.kind, sent: outgoing.send)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}

/// Hosts the compose view for the current request; a new request replaces the old one.
struct MailComposeWindowContent: View {
    @ObservedObject var service: MailService
    @EnvironmentObject private var localization: LocalizationService

    var body: some View {
        Group {
            if let request = service.composeRequest {
                MailComposeView(request: request, service: service)
                    .id(request.id)
            } else {
                Text(localization.tr("mail.compose.nothing"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 520, minHeight: 460)
    }
}

struct MailComposeView: View {
    @StateObject var model: MailComposeModel
    @EnvironmentObject private var localization: LocalizationService
    @Environment(\.dismiss) private var dismiss

    init(request: MailComposeRequest, service: MailService) {
        _model = StateObject(wrappedValue: MailComposeModel(request: request, service: service))
    }

    private var title: String {
        switch model.request.kind {
        case .new: localization.tr("mail.compose.title.new")
        case .reply: localization.tr("mail.compose.title.reply")
        case .replyAll: localization.tr("mail.compose.title.replyAll")
        case .forward: localization.tr("mail.compose.title.forward")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            recipientRow(localization.tr("mail.compose.to"), field: .to, list: model.to, input: $model.toInput)
            Divider()
            recipientRow(localization.tr("mail.compose.cc"), field: .cc, list: model.cc, input: $model.ccInput)
            Divider()
            HStack(spacing: 8) {
                Text(localization.tr("mail.compose.subject")).foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
                TextField("", text: $model.subject).textFieldStyle(.plain)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .font(.system(size: 13))
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            Divider()
            if !model.suggestions.isEmpty { suggestionList; Divider() }
            VStack(alignment: .leading, spacing: 8) {
                if !model.externalDomains.isEmpty {
                    warning(localization.tr("mail.compose.external", model.externalDomains.joined(separator: ", ")))
                }
                if !model.invalidRecipients.isEmpty {
                    warning(localization.tr("mail.compose.invalid", model.invalidRecipients.joined(separator: ", ")))
                }
                TextEditor(text: $model.body)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .frame(maxHeight: .infinity)
                if let original = model.request.original, model.request.kind != .new {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(localization.tr("mail.compose.quoted", original.from?.displayName ?? "", MailPresentation.fullTime(original.received, localization: localization)))
                            .font(.system(size: 11, weight: .medium))
                        Text(original.preview).font(.system(size: 11)).lineLimit(3)
                        if model.request.kind == .forward, !original.visibleAttachments.isEmpty {
                            Label(localization.tr("mail.compose.forwardAttachments", original.visibleAttachments.map(\.name).joined(separator: ", ")), systemImage: "paperclip")
                                .font(.system(size: 11))
                        }
                    }
                    .foregroundStyle(.secondary)
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) { Rectangle().fill(Color.secondary.opacity(0.4)).frame(width: 2) }
                }
                Label(localization.tr("mail.compose.noAttachments"), systemImage: "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .opacity(model.isLocked ? 0.55 : 1)
            .disabled(model.isLocked)
            Divider()
            footer
        }
        .navigationTitle(title)
        .onChange(of: model.phase) { phase in
            if case .done = phase { dismiss() }
        }
    }

    private func recipientRow(_ label: String, field: MailComposeModel.Field, list: [String], input: Binding<String>) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
            FlowRow(spacing: 5) {
                ForEach(list, id: \.self) { address in
                    let external = model.service.isExternal(address)
                    let invalid = !MCPCalendarTools.isEmailAddress(address)
                    HStack(spacing: 4) {
                        Text(address).font(.system(size: 12))
                        Button { model.remove(address) } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill((invalid ? Color.red : external ? Color.orange : Color.accentColor).opacity(0.16)))
                    .overlay(Capsule().strokeBorder(external || invalid ? (invalid ? Color.red : Color.orange).opacity(0.5) : .clear, lineWidth: 1))
                    .help(external ? localization.tr("mail.external") : address)
                }
                TextField("", text: input)
                    .textFieldStyle(.plain)
                    .frame(minWidth: 160)
                    .onSubmit { model.commit(field) }
                    .onChange(of: input.wrappedValue) { _ in model.inputChanged(field) }
            }
        }
        .font(.system(size: 13))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .disabled(model.isLocked)
    }

    private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(model.suggestions) { person in
                Button { model.pick(person) } label: {
                    HStack(spacing: 8) {
                        Text(person.displayName).font(.system(size: 12, weight: .medium))
                        Text(person.email).font(.system(size: 11)).foregroundStyle(.secondary)
                        if let title = person.jobTitle { Text(title).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1) }
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .background(Color.accentColor.opacity(0.05))
    }

    private func warning(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            Text(text).font(.system(size: 12))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.13)))
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 8) {
            switch model.phase {
            case .countdown(let remaining):
                Image(systemName: "paperplane").foregroundStyle(Color.accentColor)
                Text(localization.tr("mail.compose.sendingIn", remaining)).font(.system(size: 13))
                Spacer()
                Button(localization.tr("mail.compose.undo")) { model.undo() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.borderedProminent)
            case .sending:
                ProgressView().controlSize(.small)
                Text(localization.tr("mail.compose.sending")).font(.system(size: 13))
                Spacer()
            default:
                Button(localization.tr("mail.compose.saveDraft")) { model.saveDraft() }
                if case .failed(let message) = model.phase {
                    Text(message).font(.system(size: 11)).foregroundStyle(.red).lineLimit(2)
                }
                Spacer()
                Button(localization.tr("mail.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    model.send()
                } label: {
                    Label(localization.tr("mail.compose.send"), systemImage: "paperplane")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canSend && model.toInput.isEmpty)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
