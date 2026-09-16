import Foundation

/// WBXML 1.3 codec, profiled for Exchange ActiveSync as specified in [MS-ASWBXML].
///
/// EAS does not send plain XML. Tag names are compressed to single-byte tokens whose
/// meaning depends on the *currently active code page*, and the stream switches pages
/// inline. A single `Provision` request touches two pages; a calendar `Sync` touches four.
///
/// The consequence that shapes this file: the same byte means different things on
/// different pages — `0x08` is `Set` on page 18 and `PolicyType` on page 14. Navigation
/// therefore matches on ``WBTag`` (page *and* code), never on the name alone.

// MARK: - Writing

/// Encoder for WBXML request bodies.
///
/// Not thread-safe by design: build one per request, on the caller's isolation.
final class WBXMLWriter {
    private var out = Data()
    private var currentPage = -1

    init() {
        out.append(0x03)      // WBXML version 1.3
        out.append(0x01)      // public identifier: unknown
        appendMultiByte(106)  // charset: UTF-8
        appendMultiByte(0)    // empty string table
    }

    private func appendMultiByte(_ value: Int) {
        var v = value
        var bytes: [UInt8] = [UInt8(v & 0x7F)]
        v >>= 7
        while v > 0 {
            bytes.insert(UInt8((v & 0x7F) | 0x80), at: 0)
            v >>= 7
        }
        out.append(contentsOf: bytes)
    }

    private func switchPage(_ page: Int) {
        guard page != currentPage else { return }
        out.append(0x00)              // SWITCH_PAGE
        out.append(UInt8(page))
        currentPage = page
    }

    /// Opens a tag that has content. Must be balanced by ``close()``.
    func open(_ tag: WBTag) {
        switchPage(tag.page)
        out.append(UInt8(tag.code) | 0x40)   // 0x40 = "tag with content"
    }

    /// Writes a tag with no content and no children.
    func empty(_ tag: WBTag) {
        switchPage(tag.page)
        out.append(UInt8(tag.code))
    }

    func close() { out.append(0x01) }        // END

    func text(_ value: String) {
        out.append(0x03)                     // STR_I, inline NUL-terminated string
        out.append(contentsOf: Array(value.utf8))
        out.append(0x00)
    }

    /// `<tag>value</tag>`
    func leaf(_ tag: WBTag, _ value: String) {
        open(tag); text(value); close()
    }

    /// `<tag>` … `</tag>` around `body`.
    func node(_ tag: WBTag, _ body: () -> Void) {
        open(tag); body(); close()
    }

    var data: Data { out }
}

// MARK: - Reading

/// One node of a decoded WBXML document.
indirect enum WBNode: Sendable {
    case element(WBTag, [WBNode])
    case text(String)
    case opaque(Data)
}

struct WBXMLReader {
    /// Guards against a malformed document driving unbounded recursion.
    private static let maxDepth = 64

    private let bytes: [UInt8]
    private var i = 0
    private var page = 0

    private init(_ data: Data) { bytes = [UInt8](data) }

    static func parse(_ data: Data) throws -> [WBNode] {
        var reader = WBXMLReader(data)
        return try reader.run()
    }

    private mutating func run() throws -> [WBNode] {
        // 4 bytes is the smallest possible header (version, public id, charset, table length).
        guard bytes.count > 4 else {
            throw EASError.protocolError("WBXML document is empty or truncated")
        }
        _ = readByte()          // version
        _ = readMultiByte()     // public identifier
        _ = readMultiByte()     // charset
        let tableLength = readMultiByte()
        // Clamp: a corrupt length must not push the cursor past the buffer.
        i = min(i + tableLength, bytes.count)

        var nodes: [WBNode] = []
        while i < bytes.count, let node = parseNode(depth: 0) {
            nodes.append(node)
        }
        return nodes
    }

    private mutating func readByte() -> UInt8 {
        guard i < bytes.count else { return 0 }
        defer { i += 1 }
        return bytes[i]
    }

    private mutating func readMultiByte() -> Int {
        var result = 0
        while i < bytes.count {
            let b = bytes[i]; i += 1
            let payload = Int(b & 0x7F)
            // Multi-byte integers are used as lengths and offsets. Clamp malformed values to
            // the input size before arithmetic can overflow or move the cursor backwards.
            guard result <= (bytes.count - payload) / 128 else { return bytes.count }
            result = result * 128 + payload
            if b & 0x80 == 0 { break }
        }
        return result
    }

    /// Returns `nil` at an END marker or end of input — that is how a child list terminates.
    private mutating func parseNode(depth: Int) -> WBNode? {
        guard depth < Self.maxDepth else { return nil }
        guard i < bytes.count else { return nil }
        let b = bytes[i]

        switch b {
        case 0x00:                       // SWITCH_PAGE
            i += 1
            page = Int(readByte())
            return parseNode(depth: depth + 1)

        case 0x01:                       // END
            i += 1
            return nil

        case 0x02:                       // ENTITY — unused by EAS
            i += 1
            _ = readMultiByte()
            return parseNode(depth: depth + 1)

        case 0x03:                       // STR_I
            i += 1
            var buffer: [UInt8] = []
            while i < bytes.count, bytes[i] != 0x00 { buffer.append(bytes[i]); i += 1 }
            i += 1                       // consume the terminator
            return .text(String(decoding: buffer, as: UTF8.self))

        case 0xC3:                       // OPAQUE
            i += 1
            let length = readMultiByte()
            let end = min(i + length, bytes.count)
            let slice = Data(bytes[i..<end])
            i = end
            return .opaque(slice)

        default:
            let hasContent = (b & 0x40) != 0
            let hasAttributes = (b & 0x80) != 0
            let code = Int(b & 0x3F)
            i += 1
            let tag = WBTag(page: page, code: code, name: EASCodePages.name(page: page, code: code))

            if hasAttributes {           // EAS never emits attributes; skip the list defensively
                while i < bytes.count, bytes[i] != 0x01 { i += 1 }
                if i < bytes.count { i += 1 }
            }

            var children: [WBNode] = []
            if hasContent {
                while let child = parseNode(depth: depth + 1) { children.append(child) }
            }
            return .element(tag, children)
        }
    }
}

// MARK: - Navigation

extension WBNode {
    var tag: WBTag? {
        if case .element(let t, _) = self { return t }
        return nil
    }

    var children: [WBNode] {
        if case .element(_, let c) = self { return c }
        return []
    }

    /// All text content of this node, concatenated.
    var text: String {
        switch self {
        case .text(let s):       return s
        case .opaque(let d):     return String(decoding: d, as: UTF8.self)
        case .element(_, let c): return c.map(\.text).joined()
        }
    }

    // Matching is by page *and* code. Matching by name would silently confuse
    // `Status` and `Body`, which exist on several pages with different tokens.

    func child(_ tag: WBTag) -> WBNode? {
        children.first { $0.tag == tag }
    }

    func all(_ tag: WBTag) -> [WBNode] {
        children.filter { $0.tag == tag }
    }

    func value(_ tag: WBTag) -> String? {
        child(tag)?.text
    }

    /// Depth-first search, for responses whose nesting varies by Exchange build.
    func first(_ tag: WBTag) -> WBNode? {
        if self.tag == tag { return self }
        for child in children {
            if let found = child.first(tag) { return found }
        }
        return nil
    }

    /// Human-readable tree, for the `#if DEBUG` traffic dump.
    ///
    /// Any element printed as `pN_0xNN` is a token this build does not map — which is how
    /// an unmapped code page gets found without guessing.
    func dumped(_ depth: Int = 0) -> String {
        let pad = String(repeating: "  ", count: depth)
        switch self {
        case .text(let s):
            return "\(pad)\"\(s.prefix(120))\"\n"
        case .opaque(let d):
            return "\(pad)<opaque \(d.count) bytes>\n"
        case .element(let t, let c):
            if c.count == 1, case .text(let s) = c[0] {
                return "\(pad)<\(t.name)> \(s.prefix(120))\n"
            }
            return "\(pad)<\(t.name)>\n" + c.map { $0.dumped(depth + 1) }.joined()
        }
    }
}

extension Array where Element == WBNode {
    func first(_ tag: WBTag) -> WBNode? {
        for node in self {
            if let found = node.first(tag) { return found }
        }
        return nil
    }

    var dumped: String { map { $0.dumped() }.joined() }
}

extension WBNode {
    /// Names of tokens this build does not map, as `pN_0xNN`.
    ///
    /// These are the one part of a response safe to put in the unified log: a token name is a
    /// protocol identifier and carries no mailbox data, unlike the tree around it. Surfacing
    /// them is the whole verification procedure for a code-page table — an unmapped token is a
    /// field silently going nowhere.
    var unmappedTokens: Set<String> {
        var found: Set<String> = []
        collectUnmappedTokens(into: &found)
        return found
    }

    private func collectUnmappedTokens(into found: inout Set<String>) {
        if case .element(let tag, let children) = self {
            if EASCodePages.pages[tag.page]?[tag.code] == nil {
                found.insert(tag.name)
            }
            for child in children {
                child.collectUnmappedTokens(into: &found)
            }
        }
    }
}

extension Array where Element == WBNode {
    var unmappedTokens: Set<String> {
        reduce(into: Set<String>()) { $0.formUnion($1.unmappedTokens) }
    }
}
