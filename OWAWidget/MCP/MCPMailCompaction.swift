import Foundation

/// The compact view of `get_mail_thread`: what repeats from message to message stays out, so a
/// long conversation costs a model a fraction of the context. Pure functions, no state.
enum MCPMailCompaction {
    // MARK: - Subject

    /// Reply and forward prefixes, in the languages of the mail this app meets: `RE:`, `FW:`,
    /// `Fwd:`, `Ответ:`, `Отв:`, `Пересл.:`, German `AW:`/`WG:`, and numbered `RE[2]:`.
    private static let subjectPrefixes = ["re", "fw", "fwd", "ответ", "отв", "пересл", "aw", "wg", "tr", "rv"]

    /// The subject without its reply and forward prefixes, spaces collapsed, for comparing.
    static func baseSubject(_ subject: String) -> String {
        var rest = Substring(subject.trimmingCharacters(in: .whitespacesAndNewlines))
        while true {
            guard let colon = rest.firstIndex(where: { $0 == ":" || $0 == "：" }) else { break }
            var head = rest[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            if head.hasSuffix("]"), let open = head.lastIndex(of: "[") {
                guard head[head.index(after: open)..<head.index(before: head.endIndex)].allSatisfy(\.isNumber) else { break }
                head = String(head[..<open])
            }
            if head.hasSuffix(".") { head.removeLast() }
            guard subjectPrefixes.contains(head) else { break }
            rest = rest[rest.index(after: colon)...].drop(while: \.isWhitespace)
        }
        return rest.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    /// Whether a message's subject only repeats the conversation's (prefixes aside).
    static func repeatsTopic(_ subject: String, topic: String) -> Bool {
        baseSubject(subject) == baseSubject(topic)
    }

    // MARK: - Recipients

    /// The key a recipient is compared by: the address, or the name when there is none.
    static func recipientKey(_ address: MailAddress) -> String {
        if let email = address.email?.trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty { return email.lowercased() }
        return address.displayName.lowercased()
    }

    struct RecipientChange: Equatable {
        /// On the newest message, not on this one.
        let added: [MailAddress]
        /// On this message, not on the newest one.
        let removed: [MailAddress]
        var isEmpty: Bool { added.isEmpty && removed.isEmpty }
    }

    /// How the people of a message went from `message` to `newest`. Moving someone from `to`
    /// to `cc` (or to the sender) is not a change: a model needs who took part.
    static func recipientChange(from message: [MailAddress], to newest: [MailAddress]) -> RecipientChange {
        let mine = Set(message.map(recipientKey))
        let theirs = Set(newest.map(recipientKey))
        var seen = Set<String>()
        let added = newest.filter { !mine.contains(recipientKey($0)) && seen.insert(recipientKey($0)).inserted }
        seen = []
        let removed = message.filter { !theirs.contains(recipientKey($0)) && seen.insert(recipientKey($0)).inserted }
        return RecipientChange(added: added, removed: removed)
    }

    // MARK: - Signature

    /// Lines a signature opens with. Only these: a block of short lines without one is not cut,
    /// since a short reply, a list or a table row looks the same.
    private static let signatureOpeners = [
        "с уважением", "с наилучшими пожеланиями", "всего доброго", "всего хорошего",
        "best regards", "kind regards", "warm regards", "regards", "best wishes", "sincerely", "cheers",
    ]
    /// At most this many non-empty lines after the opener.
    static let maxSignatureLines = 12
    /// Each of them at most this long: a long line is text, not a signature.
    static let maxSignatureLineLength = 100

    /// `text` without the signature at its end, or nil when there is none it is sure of. The
    /// signature starts at a line that is only a closing phrase ("С уважением,", "Best regards",
    /// "Best regards, Alex") or `--`, and runs to the end in a few short lines. After `--` one of
    /// them must look like contact details (a phone, an address, a link): a bare `--` is also a
    /// separator inside a message. The last such start counts, so an earlier "С уважением" in the
    /// text does not take the rest with it. Text must remain before it.
    static func strippingSignature(_ text: String) -> String? {
        let lines = text.components(separatedBy: "\n")
        for index in lines.indices.reversed() {
            guard let opener = signatureOpener(lines[index]) else { continue }
            let tail = lines[(index + 1)...].map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard tail.count <= maxSignatureLines, tail.allSatisfy({ $0.count <= maxSignatureLineLength }) else { return nil }
            if opener == .dashes, !tail.contains(where: looksLikeContact) { return nil }
            let body = lines[..<index].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return body.isEmpty ? nil : body
        }
        return nil
    }

    private enum Opener { case phrase, dashes }

    private static func signatureOpener(_ line: String) -> Opener? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed == "--" { return .dashes }
        guard trimmed.count <= 60 else { return nil }
        let lower = trimmed.lowercased()
        for opener in signatureOpeners where lower.hasPrefix(opener) {
            // After the phrase: only punctuation, or a name — "Regards, Alex", "С уважением, Иван
            // Петров". "Cheers to everyone who helped:" and "Regardless of …" are text.
            let rest = trimmed.dropFirst(opener.count)
            if let first = rest.first, first.isLetter { continue }
            let words = rest.split { $0.isWhitespace || ",.!;:—-".contains($0) }
            if words.isEmpty { return .phrase }
            if words.count <= 3, words.allSatisfy({ $0.first?.isUppercase == true && $0.allSatisfy(\.isLetter) }) { return .phrase }
        }
        return nil
    }

    /// A phone (7+ digits), an email address or a link.
    private static func looksLikeContact(_ line: String) -> Bool {
        line.filter(\.isNumber).count >= 7 || line.contains("@") || line.lowercased().contains("http") || line.lowercased().contains("www.")
    }
}
