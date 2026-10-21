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
        /// Exchange would send to other people than the ones in the fields: the user decides.
        case review(MailPreparedSend)
        case failed(String)
        case done(MailOutgoing.Kind, sent: Bool)
    }

    static let undoSeconds = 5

    @Published var to: [String]
    @Published var cc: [String]
    @Published var toInput = ""
    @Published var ccInput = ""
    @Published var subject: String
    @Published var body: RichText
    /// Pictures pasted into `body`, in the order of its U+FFFC marks.
    @Published var bodyImages: [MailInlineImage] = []
    @Published private(set) var phase: Phase = .editing
    @Published private(set) var suggestions: [ResolvedAttendee] = []
    @Published var suggestionField: Field?
    /// The suggestion Return would pick; ↑/↓ move it.
    @Published private(set) var highlightedSuggestion = 0
    /// The directory is being asked for what is in the field.
    @Published private(set) var isSearchingPeople = false
    /// The last search for this text came back empty: said so, or the field looks dead.
    @Published private(set) var foundNoPeople = false
    /// Names for the addresses in the fields, by lowercased address: the original's people and
    /// the ones picked from the directory. A typed address has none.
    @Published private(set) var names: [String: String] = [:]

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
        body = RichText(plain: request.body)
        defaultSubject = request.subject
        if let original = request.original {
            for person in [original.from].compactMap({ $0 }) + original.to + original.cc + original.bcc {
                guard let email = person.email, !person.name.contains("@") else { continue }
                let name = person.name.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { names[email.lowercased()] = name }
            }
        }
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

    var imagesBytes: Int { bodyImages.reduce(0) { $0 + $1.data.count } }

    /// Exchange would refuse the message: said so, and nothing goes until a picture is removed.
    var imagesTooLarge: Bool { imagesBytes > MailInlineImage.maxTotalBytes }

    var canSend: Bool {
        !isLocked && invalidRecipients.isEmpty && !to.isEmpty && !imagesTooLarge
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
        dismissSuggestions()
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
        if !person.displayName.isEmpty, !person.displayName.contains("@") { names[person.email.lowercased()] = person.displayName }
        add(person.email, to: field)
        if field == .to { toInput = "" } else { ccInput = "" }
        dismissSuggestions()
    }

    // MARK: - Chips

    /// Chips a field shows while it is not being edited; the rest hide behind "N more".
    static let collapsedChipLimit = 8

    /// The chips of a field that is not being edited: the first `limit`, plus every flagged
    /// (external, invalid) address wherever it is — those never hide behind "N more" — in the
    /// field's order, and how many are left out. One left out would cost as much room as it saves.
    static func collapsed(_ list: [String], limit: Int, flagged: (String) -> Bool) -> (shown: [String], hidden: Int) {
        guard list.count > limit + 1 else { return (list, 0) }
        var room = max(limit - list.filter(flagged).count, 0)
        let shown = list.filter { address in
            if flagged(address) { return true }
            guard room > 0 else { return false }
            room -= 1
            return true
        }
        return (shown, list.count - shown.count)
    }

    func collapsed(_ field: Field) -> (shown: [String], hidden: Int) {
        Self.collapsed(field == .to ? to : cc, limit: Self.collapsedChipLimit) { [service] address in
            service.isExternal(address) || !MCPCalendarTools.isEmailAddress(address)
        }
    }

    func chipLabel(_ address: String) -> String {
        Self.chipLabel(address, name: names[address.lowercased()], ownDomain: service.ownDomain)
    }

    /// What a chip says: the person's name, short; without one, the address — for the user's own
    /// domain only the part before @, the same on every chip otherwise.
    static func chipLabel(_ address: String, name: String?, ownDomain: String?) -> String {
        if let name, !name.contains("@") {
            let short = shortName(name)
            if !short.isEmpty { return short }
        }
        if let domain = ownDomain, let at = address.lastIndex(of: "@"), at > address.startIndex,
           address[address.index(after: at)...].lowercased() == domain {
            return String(address[..<at])
        }
        return address
    }

    /// "Попов Александр Васильевич" → "Попов Александр": the patronymic only takes room. Other
    /// names stay whole.
    static func shortName(_ name: String) -> String {
        let words = name.split(whereSeparator: \.isWhitespace).map(String.init)
        let cyrillic = { (word: String) in word.unicodeScalars.allSatisfy { (0x0400...0x04FF).contains($0.value) || $0 == "-" } }
        if words.count == 3, words.allSatisfy(cyrillic),
           ["ич", "вна", "чна"].contains(where: { words[2].lowercased().hasSuffix($0) }) {
            return words.prefix(2).joined(separator: " ")
        }
        return words.joined(separator: " ")
    }

    /// Whether the dropdown under `field` has anything to show: people, a search under way, or
    /// "nobody found".
    func showsSuggestions(for field: Field) -> Bool {
        suggestionField == field && (!suggestions.isEmpty || isSearchingPeople || foundNoPeople)
    }

    func moveHighlight(by delta: Int) {
        guard !suggestions.isEmpty else { return }
        highlightedSuggestion = (highlightedSuggestion + delta + suggestions.count) % suggestions.count
    }

    /// Return in a recipient field: the highlighted person when the dropdown lists anyone —
    /// a typed name is not an address — otherwise what was typed. While a search for newer text
    /// is on its way the dropdown still lists the people found for the older one: Return then
    /// does nothing, rather than pick one of them.
    func submit(_ field: Field) {
        if suggestionField == field, isSearchingPeople { return }
        if suggestionField == field, suggestions.indices.contains(highlightedSuggestion) {
            pick(suggestions[highlightedSuggestion])
        } else {
            commit(field)
        }
    }

    func dismissSuggestions() {
        suggestTask?.cancel()
        suggestions = []
        highlightedSuggestion = 0
        isSearchingPeople = false
        foundNoPeople = false
    }

    func inputChanged(_ field: Field) {
        suggestionField = field
        let text = (field == .to ? toInput : ccInput).trimmingCharacters(in: .whitespaces)
        if text.hasSuffix(",") || text.hasSuffix(";") {
            commit(field)
            return
        }
        guard text.count >= 2, !text.contains("@") else {
            dismissSuggestions()
            return
        }
        suggestTask?.cancel()
        isSearchingPeople = true
        suggestTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let self else { return }
            let found = await self.service.suggestRecipients(text)
            guard !Task.isCancelled else { return }
            self.suggestions = Array(found.prefix(8))
            self.highlightedSuggestion = 0
            self.isSearchingPeople = false
            self.foundNoPeople = found.isEmpty
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
            send: send,
            inlineImages: bodyImages
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
        guard invalidRecipients.isEmpty, !imagesTooLarge else { return }
        let outgoing = outgoing(send: false)
        phase = .sending
        Task {
            do {
                _ = try await service.saveDraft(outgoing)
                phase = .done(outgoing.kind, sent: false)
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    /// Draft on the server, read back, then sent — or shown first when Exchange put other people
    /// on it than the ones in the fields (a Reply-To, someone removed from a reply-all).
    private func deliver(_ outgoing: MailOutgoing) async {
        phase = .sending
        do {
            let prepared = try await service.prepareSend(outgoing)
            if prepared.matchesRequest {
                try await service.sendPrepared(prepared)
                phase = .done(outgoing.kind, sent: true)
            } else {
                phase = .review(prepared)
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// The user saw who Exchange would send to and agreed.
    func confirmReviewed() {
        guard case .review(let prepared) = phase else { return }
        phase = .sending
        Task {
            do {
                try await service.sendPrepared(prepared)
                phase = .done(prepared.outgoing.kind, sent: true)
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    /// Back to editing; the review draft goes away.
    func cancelReviewed() {
        guard case .review(let prepared) = phase else { return }
        phase = .editing
        Task { await service.discardPrepared(prepared) }
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
                    // The compose window can open without the mail window (an assistant's draft):
                    // it needs the user's address for the external-recipient check itself.
                    .task(id: request.id) { await service.resolveOwnAddress() }
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
    @FocusState private var focusedField: FocusedField?
    @StateObject private var editorController = RichTextEditorController()
    @State private var originalHeight: CGFloat = 80
    @State private var showsOriginal = true
    /// The recipient field shown in full: the one being edited, or opened with "N more". Kept
    /// apart from the focus: the text editor is AppKit, and moving into it leaves the SwiftUI
    /// focus where it was.
    @State private var expandedField: MailComposeModel.Field?

    private enum FocusedField: Hashable { case recipients(MailComposeModel.Field), subject }

    init(request: MailComposeRequest, service: MailService) {
        _model = StateObject(wrappedValue: MailComposeModel(request: request, service: service))
    }

    /// As wide as the longest of "To", "Cc" and "Subject" in the current language: a fixed width
    /// left a gap after the short Russian labels and could clip a longer translation.
    private var labelColumnWidth: CGFloat {
        let font = NSFont.systemFont(ofSize: 13)
        let widths = ["mail.compose.to", "mail.compose.cc", "mail.compose.subject"].map {
            (localization.tr($0) as NSString).size(withAttributes: [.font: font]).width
        }
        return ceil(widths.max() ?? 0)
    }

    private var title: String {
        switch model.request.kind {
        case .new: localization.tr("mail.compose.title.new")
        case .reply: localization.tr("mail.compose.title.reply")
        case .replyAll: localization.tr("mail.compose.title.replyAll")
        case .forward: localization.tr("mail.compose.title.forward")
        }
    }

    /// The message replied to, as the reader shows it: no scripts, no remote images. Links do
    /// nothing here; the reader is where to follow them. Long ones scroll in a box of their own.
    private func originalView(_ document: String) -> some View {
        ScrollView {
            MailMessageWebView(html: document, height: $originalHeight, copyTitle: localization.tr("mail.action.copy")) { _ in }
                .frame(height: originalHeight)
        }
        .frame(height: min(max(originalHeight, 40), 240))
        .padding(.top, 4)
    }

    var body: some View {
        VStack(spacing: 0) {
            recipientRow(localization.tr("mail.compose.to"), field: .to, list: model.to, input: $model.toInput)
            suggestionDivider(for: .to)
            recipientRow(localization.tr("mail.compose.cc"), field: .cc, list: model.cc, input: $model.ccInput)
            suggestionDivider(for: .cc)
            HStack(spacing: 8) {
                Text(localization.tr("mail.compose.subject")).foregroundStyle(.secondary).frame(width: labelColumnWidth, alignment: .leading)
                TextField("", text: $model.subject).textFieldStyle(.plain).focused($focusedField, equals: .subject)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .font(.system(size: 13))
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            Divider()
            RichTextToolbar(controller: editorController)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .opacity(model.isLocked ? 0.55 : 1)
                .disabled(model.isLocked)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                if model.service.ownDomain == nil, !model.allRecipients.isEmpty {
                    // Fail visible, not open: without the user's own domain no address can be
                    // told external.
                    warning(localization.tr("mail.compose.externalUnknown"))
                } else if !model.externalDomains.isEmpty {
                    warning(localization.tr("mail.compose.external", model.externalDomains.joined(separator: ", ")))
                }
                if !model.invalidRecipients.isEmpty {
                    warning(localization.tr("mail.compose.invalid", model.invalidRecipients.joined(separator: ", ")))
                }
                if model.imagesTooLarge {
                    warning(localization.tr(
                        "mail.compose.imagesTooLarge",
                        ByteCountFormatter.string(fromByteCount: Int64(model.imagesBytes), countStyle: .file),
                        ByteCountFormatter.string(fromByteCount: Int64(MailInlineImage.maxTotalBytes), countStyle: .file)
                    ))
                }
                // Moving into the text closes a recipient dropdown, as moving to another field does.
                RichTextEditor(text: $model.body, images: $model.bodyImages, controller: editorController, onFocus: {
                    model.dismissSuggestions()
                    expandedField = nil
                    // Or a click back into the same recipient field would change nothing.
                    focusedField = nil
                })
                    .frame(maxHeight: .infinity)
                if let original = model.request.original, model.request.kind != .new {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(localization.tr("mail.compose.quoted", original.from?.displayName ?? "", MailPresentation.fullTime(original.received, localization: localization)))
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                            if model.request.originalDocument != nil {
                                Button {
                                    showsOriginal.toggle()
                                } label: {
                                    Image(systemName: showsOriginal ? "chevron.down" : "chevron.right")
                                        .font(.system(size: 10, weight: .semibold))
                                        .frame(width: 18, height: 16)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help(localization.tr(showsOriginal ? "mail.compose.original.hide" : "mail.compose.original.show"))
                            }
                        }
                        if let document = model.request.originalDocument {
                            if showsOriginal { originalView(document) }
                        } else {
                            Text(original.preview).font(.system(size: 11)).lineLimit(3)
                        }
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
        .onChange(of: focusedField) { focused in
            if case .recipients(let field) = focused { expandedField = field } else if focused != nil { expandedField = nil }
            // Moving to another field closes the dropdown. Losing focus altogether does not:
            // a click on a suggestion may be what took it.
            guard let focused, focused != model.suggestionField.map(FocusedField.recipients) else { return }
            model.dismissSuggestions()
        }
        .background(MailComposeKeyMonitor(isActive: model.suggestionField != nil, onKey: handleSuggestionKey))
    }

    /// ↑/↓ walk the dropdown, Return picks, Esc closes it. Only while a recipient field with an
    /// open dropdown has focus; everything else keeps its usual meaning.
    private func handleSuggestionKey(_ key: MailComposeKeyMonitor.Key) -> Bool {
        guard let field = model.suggestionField, focusedField == .recipients(field), model.showsSuggestions(for: field) else { return false }
        switch key {
        case .down: model.moveHighlight(by: 1)
        case .up: model.moveHighlight(by: -1)
        case .escape: model.dismissSuggestions()
        case .returnKey:
            guard !model.suggestions.isEmpty else { return false }
            model.submit(field)
        }
        return true
    }

    private func recipientRow(_ label: String, field: MailComposeModel.Field, list: [String], input: Binding<String>) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).foregroundStyle(.secondary).frame(width: labelColumnWidth, alignment: .leading)
            // A long reply-all list folds to its first chips while the field is not being edited,
            // so the text keeps its room; focus in the field shows everyone.
            let editing = expandedField == field || model.showsSuggestions(for: field)
            let (shown, hidden) = editing ? (list, 0) : model.collapsed(field)
            FlowRow(spacing: 5) {
                ForEach(shown, id: \.self) { address in
                    recipientChip(address)
                }
                if hidden > 0 {
                    Button {
                        expandedField = field
                        focusedField = .recipients(field)
                    } label: {
                        Text(localization.tr("mail.compose.moreRecipients", hidden))
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.secondary.opacity(0.14)))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(localization.tr("mail.compose.moreRecipients.help"))
                }
                TextField("", text: input)
                    .textFieldStyle(.plain)
                    .frame(minWidth: 160)
                    .focused($focusedField, equals: .recipients(field))
                    .onSubmit { model.submit(field) }
                    .onChange(of: input.wrappedValue) { _ in model.inputChanged(field) }
            }
        }
        .font(.system(size: 13))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .disabled(model.isLocked)
    }

    /// A recipient by name, or by the part before @ in the user's own domain; the whole address
    /// is in the tooltip. External ones are orange, unusable ones red.
    private func recipientChip(_ address: String) -> some View {
        let external = model.service.isExternal(address)
        let invalid = !MCPCalendarTools.isEmailAddress(address)
        let name = model.names[address.lowercased()]
        var tooltip = name.map { "\($0) <\(address)>" } ?? address
        if external { tooltip += " — " + localization.tr("mail.external") }
        return HStack(spacing: 4) {
            Text(model.chipLabel(address))
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 260)
            Button { model.remove(address) } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                .buttonStyle(.mailIconCompact)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(Capsule().fill((invalid ? Color.red : external ? Color.orange : Color.accentColor).opacity(0.16)))
        .overlay(Capsule().strokeBorder(external || invalid ? (invalid ? Color.red : Color.orange).opacity(0.5) : .clear, lineWidth: 1))
        .help(tooltip)
    }

    /// The divider under a recipient row carries that row's dropdown: hung from the divider's top
    /// edge it starts right below the field and never covers what is being typed. On top of the
    /// rows after it, which it overlaps.
    private func suggestionDivider(for field: MailComposeModel.Field) -> some View {
        Divider()
            .overlay(alignment: .topLeading) {
                if model.showsSuggestions(for: field) {
                    suggestionList
                        .fixedSize(horizontal: false, vertical: true)
                        // Under the text column, a little out so the row text lines up.
                        .padding(.leading, 14 + labelColumnWidth + 8 - 8)
                        .padding(.trailing, 14)
                        .padding(.top, 2)
                }
            }
            .zIndex(model.suggestionField == field ? 1 : 0)
    }

    private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.suggestions.isEmpty {
                HStack(spacing: 8) {
                    if model.isSearchingPeople { ProgressView().controlSize(.small) }
                    Text(localization.tr(model.isSearchingPeople ? "mail.compose.searchingPeople" : "mail.compose.noPeople"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            ForEach(Array(model.suggestions.enumerated()), id: \.element.id) { index, person in
                let highlighted = index == model.highlightedSuggestion
                Button {
                    let field = model.suggestionField ?? .to
                    model.pick(person)
                    // Back to the field, ready for the next name.
                    focusedField = .recipients(field)
                } label: {
                    HStack(spacing: 8) {
                        Text(person.displayName).font(.system(size: 12, weight: .medium))
                            .foregroundStyle(highlighted ? Color.white : Color.primary)
                        Text(person.email).font(.system(size: 11))
                            .foregroundStyle(highlighted ? Color.white.opacity(0.85) : Color.secondary)
                        if let title = person.jobTitle {
                            Text(title).font(.system(size: 11)).lineLimit(1)
                                .foregroundStyle(highlighted ? Color.white.opacity(0.7) : Color.secondary.opacity(0.8))
                        }
                        Spacer(minLength: 0)
                    }
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 5).fill(highlighted ? Color.accentColor : Color.clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.mailRow(cornerRadius: 5))
            }
        }
        .padding(4)
        .frame(maxWidth: 520, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
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

    /// Who Exchange would send to beyond the fields, and who it dropped. No default button: the
    /// user reads the names and chooses.
    private func reviewFooter(_ prepared: MailPreparedSend) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(localization.tr("mail.compose.review.title")).font(.system(size: 12, weight: .semibold))
            }
            if !prepared.addedRecipients.isEmpty {
                Text(localization.tr("mail.compose.review.added", prepared.addedRecipients.map(reviewName).joined(separator: ", ")))
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !prepared.droppedRecipients.isEmpty {
                Text(localization.tr("mail.compose.review.dropped", prepared.droppedRecipients.joined(separator: ", ")))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(localization.tr("mail.compose.review.cancel")) { model.cancelReviewed() }
                    .keyboardShortcut(.cancelAction)
                Button(localization.tr("mail.compose.review.send")) { model.confirmReviewed() }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func reviewName(_ address: MailAddress) -> String {
        guard let email = address.email else { return address.displayName }
        let label = address.displayName == email ? email : "\(address.displayName) <\(email)>"
        return model.service.isExternal(email) ? label + " (" + localization.tr("mail.external") + ")" : label
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
            case .review(let prepared):
                reviewFooter(prepared)
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

/// Arrow keys, Return and Esc for the recipient dropdown, seen before the focused text field
/// handles them (a single-line field would move the caret on ↑/↓). Only for this view's own
/// window, and not while an input method is composing text.
struct MailComposeKeyMonitor: NSViewRepresentable {
    enum Key { case up, down, returnKey, escape }

    let isActive: Bool
    /// Returns `true` when it consumed the key.
    let onKey: (Key) -> Bool

    func makeNSView(context: Context) -> MonitorView { MonitorView() }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.onKey = onKey
        view.setActive(isActive)
    }

    static func dismantleNSView(_ view: MonitorView, coordinator: ()) {
        view.setActive(false)
    }

    final class MonitorView: NSView {
        var onKey: (Key) -> Bool = { _ in false }
        private var monitor: Any?

        func setActive(_ active: Bool) {
            if active, monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    guard let self, let key = self.key(for: event) else { return event }
                    return self.onKey(key) ? nil : event
                }
            } else if !active, let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        private func key(for event: NSEvent) -> Key? {
            guard let window, event.window === window,
                  event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return nil }
            if let editor = window.firstResponder as? NSTextView, editor.hasMarkedText() { return nil }
            switch event.keyCode {
            case 125: return .down
            case 126: return .up
            case 36, 76: return .returnKey
            case 53: return .escape
            default: return nil
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { setActive(false) }
        }
    }
}
