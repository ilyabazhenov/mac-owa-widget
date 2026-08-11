import Foundation

/// Splits a converted meeting body into renderable blocks.
///
/// The body is plain text, so a wrapped bullet has no hanging indent — its second line starts at
/// the left edge and reads as a separate item ("• Кредитные каникулы - ЮЛ (новые признаки от EWS)"
/// / "(доработка)"). Rendering each bullet as marker + text lets the view keep the continuation
/// aligned under the first character.
enum MeetingBodyLayout {

    struct Block: Identifiable, Equatable {
        enum Kind: Equatable {
            case paragraph
            /// 1 = `•`, 2 = `◦` (nested list).
            case bullet(level: Int)
        }

        let id: Int
        let kind: Kind
        /// Line content without the bullet marker.
        let text: String
        /// A blank line preceded this block — the view turns it into paragraph spacing instead of
        /// an empty row.
        let hasGapBefore: Bool
    }

    static func blocks(from body: String) -> [Block] {
        var blocks: [Block] = []
        var gapPending = false

        for line in body.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else {
                // Leading blank lines carry no gap: there is nothing above them.
                gapPending = !blocks.isEmpty
                continue
            }

            let block: Block
            if let content = trimmed.dropMarker(MeetingBodyHTMLConverter.bulletPrefix) {
                block = Block(id: blocks.count, kind: .bullet(level: 1), text: content, hasGapBefore: gapPending)
            } else if let content = trimmed.dropMarker(MeetingBodyHTMLConverter.nestedBulletPrefix) {
                block = Block(id: blocks.count, kind: .bullet(level: 2), text: content, hasGapBefore: gapPending)
            } else {
                block = Block(id: blocks.count, kind: .paragraph, text: trimmed, hasGapBefore: gapPending)
            }
            blocks.append(block)
            gapPending = false
        }
        return blocks
    }
}

private extension String {
    /// Returns the text after `marker`, or `nil` when the line does not start with it.
    func dropMarker(_ marker: String) -> String? {
        guard hasPrefix(marker) else { return nil }
        return String(dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
    }
}
