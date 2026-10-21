import Foundation

/// Formatted text typed by the user: paragraphs and list items made of styled runs. Kept apart
/// from AppKit so the HTML sent to Exchange can be built and tested without an editor.
///
/// Pictures stay where they are in the text as U+FFFC (`MailInlineImage.placeholder`); the
/// pictures themselves travel next to it, in the same order.
struct RichText: Sendable, Equatable, Codable, ExpressibleByStringLiteral {
    struct Style: OptionSet, Sendable, Hashable, Codable {
        let rawValue: Int
        static let bold = Style(rawValue: 1 << 0)
        static let italic = Style(rawValue: 1 << 1)
        static let underline = Style(rawValue: 1 << 2)
        static let strikethrough = Style(rawValue: 1 << 3)
    }

    enum ListKind: String, Sendable, Equatable, Codable {
        case bullet
        case numbered
    }

    struct Run: Sendable, Equatable, Codable {
        var text: String
        var style: Style = []
        /// Only `http`, `https` and `mailto`: see `RichText.allowedLink`.
        var link: URL?
    }

    struct Block: Sendable, Equatable, Codable {
        var runs: [Run]
        /// Empty for a paragraph. For a list item, the kind of every list it sits in, outermost
        /// first: the count is how deep it is.
        var list: [ListKind] = []

        var text: String { runs.map(\.text).joined() }
        var isListItem: Bool { !list.isEmpty }
    }

    /// Deeper lists are not made: Tab stops there.
    static let maxListDepth = 5

    var blocks: [Block]

    init(blocks: [Block]) {
        self.blocks = blocks.isEmpty ? [Block(runs: [])] : blocks.map(Self.normalized)
    }

    /// Plain text as paragraphs, one per line: what an unformatted body always was.
    init(plain: String) {
        let lines = plain
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
        self.init(blocks: lines.map { Block(runs: [Run(text: String($0))]) })
    }

    init(stringLiteral value: String) {
        self.init(plain: value)
    }

    static let empty = RichText(blocks: [])

    /// The text without any formatting, list items without their markers.
    var text: String { blocks.map(\.text).joined(separator: "\n") }

    /// Nothing but whitespace and no list items.
    var isBlank: Bool {
        blocks.allSatisfy { !$0.isListItem && $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// The text as it reads without formatting: list items with "•" or their number, indented
    /// by depth. For counts, checks and places that show plain text.
    var plainText: String {
        let markers = listMarkers
        return zip(blocks, markers).map { block, marker in
            guard let marker else { return block.text }
            return String(repeating: "    ", count: block.list.count - 1) + marker + " " + block.text
        }.joined(separator: "\n")
    }

    /// Without the blank paragraphs at the start and the end, and with the whitespace there
    /// trimmed: what a meeting body keeps.
    func trimmed() -> RichText {
        var blocks = blocks
        func blank(_ block: Block) -> Bool {
            !block.isListItem && block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        while let first = blocks.first, blank(first) { blocks.removeFirst() }
        while let last = blocks.last, blank(last) { blocks.removeLast() }
        guard !blocks.isEmpty else { return .empty }
        if !blocks[0].isListItem { blocks[0].runs = Self.trimmingLeading(blocks[0].runs) }
        let lastIndex = blocks.count - 1
        if !blocks[lastIndex].isListItem { blocks[lastIndex].runs = Self.trimmingTrailing(blocks[lastIndex].runs) }
        return RichText(blocks: blocks)
    }

    /// The marker each block shows: `nil` for a paragraph, "•" for a bulleted item, "1." and on
    /// for a numbered one. Numbering goes per list: a deeper item does not break it, a shallower
    /// one or a paragraph starts the deeper ones over.
    var listMarkers: [String?] {
        var counters: [Int] = []
        var kinds: [ListKind] = []
        return blocks.map { block in
            guard block.isListItem else {
                counters = []
                kinds = []
                return nil
            }
            let depth = block.list.count
            // A list of another kind at some level is another list: its numbering starts over.
            let common = zip(kinds, block.list).prefix { $0 == $1 }.count
            counters = Array(counters.prefix(common))
            kinds = Array(block.list)
            while counters.count < depth { counters.append(0) }
            counters[depth - 1] += 1
            return block.list[depth - 1] == .bullet ? "•" : "\(counters[depth - 1])."
        }
    }

    /// A link the body may carry, or `nil`: `javascript:`, `file:` and the like go as plain text.
    static func allowedLink(_ url: URL?) -> URL? {
        guard let url, let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) else { return nil }
        return url
    }

    // MARK: - Normalizing

    /// Runs merged where they look the same, empty ones dropped, links that may not be sent
    /// dropped, the list no deeper than allowed.
    private static func normalized(_ block: Block) -> Block {
        var runs: [Run] = []
        for var run in block.runs where !run.text.isEmpty {
            run.link = allowedLink(run.link)
            if let last = runs.last, last.style == run.style, last.link == run.link {
                runs[runs.count - 1].text += run.text
            } else {
                runs.append(run)
            }
        }
        return Block(runs: runs, list: Array(block.list.prefix(maxListDepth)))
    }

    private static func trimmingLeading(_ runs: [Run]) -> [Run] {
        var runs = runs
        while let first = runs.first {
            let trimmed = String(first.text.drop { $0.isWhitespace })
            if trimmed.isEmpty { runs.removeFirst(); continue }
            runs[0].text = trimmed
            break
        }
        return runs
    }

    private static func trimmingTrailing(_ runs: [Run]) -> [Run] {
        var runs = runs
        while let last = runs.last {
            var text = last.text
            while let character = text.last, character.isWhitespace { text.removeLast() }
            if text.isEmpty { runs.removeLast(); continue }
            runs[runs.count - 1].text = text
            break
        }
        return runs
    }
}
