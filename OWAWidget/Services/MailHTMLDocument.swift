import Foundation
import ImageIO

/// Wraps a message body (HTML the server already filtered) into the document the reader loads.
///
/// The reader is locked down independently of the server's filtering: the document carries a
/// Content-Security-Policy that allows nothing but inline styles and `data:` images and fonts, the
/// web view runs no script and blocks every network load, and navigation is intercepted. So a
/// tracking pixel, a remote stylesheet or a form never reaches the network from here.
enum MailHTMLDocument {
    static let contentSecurityPolicy = "default-src 'none'; img-src data:; style-src 'unsafe-inline'; font-src data:; form-action 'none'; frame-src 'none'; base-uri 'none'"

    /// The full document for one message body.
    ///
    /// - Parameters:
    ///   - inlineImages: attachment bytes by `ContentId`, for `cid:` references.
    ///   - remoteImages: images the user chose to load for this message, by their original URL.
    static func document(
        body: String,
        inlineImages: [String: (data: Data, type: String)] = [:],
        remoteImages: [String: (data: Data, type: String)] = [:]
    ) -> String {
        func image(for source: String) -> (data: Data, type: String)? {
            if let cid = contentID(fromSource: source), let image = inlineImages[cid] ?? inlineImages[cid.lowercased()] {
                return image
            }
            return remoteImages[source]
        }
        let html = MailHTMLScanner.process(body, sanitize: true, imageSource: { source in
            image(for: source).map { dataURI($0.data, type: $0.type) }
        }, zoomLink: { source in
            guard let image = image(for: source), isZoomable(image.data) else { return nil }
            return zoomURL(forSource: source).absoluteString
        })
        return """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(contentSecurityPolicy)">
        <meta name="color-scheme" content="light">
        <style>
        html { background: #ffffff; overflow: hidden; }
        body { margin: 0; padding: 0; overflow: hidden; color: #1d1d1f; background: #ffffff;
               font: 13px -apple-system, "Helvetica Neue", Arial, sans-serif; line-height: 1.45;
               word-wrap: break-word; overflow-wrap: anywhere; }
        img { max-width: 100%; height: auto; }
        /* In an auto-width table cell a percentage max-width lets the cell squeeze the image:
           an avatar sized by the sender shrank to a sliver while its height stayed (an oval).
           A sized image keeps its size there; a message that ends up too wide is scaled as a whole. */
        td img[width], th img[width], td img[style*="width"], th img[style*="width"] { max-width: none; }
        table { max-width: 100% !important; }
        pre { white-space: pre-wrap; }
        /* Generated mail often zeroes list padding; the bullets would hang outside the page. */
        #owaw-root ul, #owaw-root ol { padding-inline-start: 1.6em !important; }
        blockquote { margin-left: 0; padding-left: 10px; border-left: 2px solid #d0d0d5; color: #555; }
        a { color: #0a66d6; }
        a.owaw-zoom { cursor: zoom-in; text-decoration: none; }
        #owaw-root { display: flow-root; padding: 12px 14px; box-sizing: border-box; }
        /* Remote images stay blocked: show a quiet placeholder instead of an empty frame. It keeps
           the size the sender gave (a 12 px badge over an avatar stays 12 px, the icon shrinks to
           fit); only an image with no size of its own gets a minimum, or it would vanish. */
        img[src^="http" i] { background: #f2f2f4 url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='16' height='16' viewBox='0 0 24 24' fill='none' stroke='%23a0a0a8' stroke-width='2'%3E%3Crect x='3' y='4' width='18' height='16' rx='2'/%3E%3Ccircle cx='9' cy='10' r='2'/%3E%3Cpath d='m21 17-5-5-9 8'/%3E%3C/svg%3E") center / min(16px, 75%) no-repeat; outline: 1px dashed #d4d4da; outline-offset: -1px; color: transparent; }
        img[src^="http" i]:not([width]):not([height]):not([style*="width"]):not([style*="height"]) { min-width: 20px; min-height: 20px; }
        </style></head>
        <body><div id="owaw-root">\(html)</div></body></html>
        """
    }

    /// Removes active and redirecting markup. Defense in depth: the server filters too, the web
    /// view runs no script and the CSP allows nothing remote, so this is not the boundary — but a
    /// document that never contains them cannot surprise anyone.
    static func sanitized(_ html: String) -> String {
        MailHTMLScanner.process(html, sanitize: true) { _ in nil }
    }

    /// `cid:abc@01D` → `abc@01D`.
    static func contentID(fromSource source: String) -> String? {
        let trimmed = source.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("cid:") else { return nil }
        let value = String(trimmed.dropFirst(4)).removingPercentEncoding ?? String(trimmed.dropFirst(4))
        return value.isEmpty ? nil : value
    }

    /// The scheme of the links that open a message's image in Quick Look; the reader intercepts
    /// every link, so these never leave the app.
    static let zoomScheme = "owaw-image"

    /// Images at least this big (in pixels, either side) open in Quick Look on a click: the
    /// reader fits them to the column, and a screenshot is then too small to read. Avatars and
    /// logos stay plain.
    static let zoomMinimumPixels = 400

    static func zoomURL(forSource source: String) -> URL {
        let encoded = Data(source.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return URL(string: zoomScheme + ":" + encoded)!
    }

    /// The image source a zoom link was made for; `nil` for any other link.
    static func zoomSource(from url: URL) -> String? {
        guard url.scheme?.lowercased() == zoomScheme else { return nil }
        var encoded = String(url.absoluteString.dropFirst(zoomScheme.count + 1))
            .replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while encoded.count % 4 != 0 { encoded += "=" }
        guard let data = Data(base64Encoded: encoded) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Reads the pixel size from the image header only; nothing is decoded.
    static func isZoomable(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return false }
        return max(width, height) >= zoomMinimumPixels
    }

    static func dataURI(_ data: Data, type: String) -> String {
        let safeType = type.range(of: "^[a-zA-Z0-9.+/-]+$", options: .regularExpression) != nil ? type : "application/octet-stream"
        return "data:\(safeType);base64,\(data.base64EncodedString())"
    }

    /// Remote (`http(s)`) image sources in a body, in order, without duplicates.
    static func remoteImageSources(in html: String) -> [String] {
        var result: [String] = []
        _ = replacingImageSources(in: html) { source in
            let lower = source.lowercased()
            if (lower.hasPrefix("https://") || lower.hasPrefix("http://")), !result.contains(source) {
                result.append(source)
            }
            return nil
        }
        return result
    }

    /// The `ContentId`s a body's images refer to (`cid:` in `src` or OWA's `originalsrc`),
    /// lowercased, without duplicates.
    static func inlineImageReferences(in html: String) -> [String] {
        var result: [String] = []
        _ = MailHTMLScanner.process(html, sanitize: false) { source in
            if let cid = contentID(fromSource: source)?.lowercased(), !result.contains(cid) { result.append(cid) }
            return nil
        }
        return result
    }

    /// Whether a body references images the reader blocked (`http(s)` sources).
    static func hasRemoteImages(_ html: String) -> Bool {
        !remoteImageSources(in: html).isEmpty
    }

    /// Rewrites every `<img src="…">` through `transform`; `nil` keeps the source.
    static func replacingImageSources(in html: String, transform: (String) -> String?) -> String {
        MailHTMLScanner.process(html, sanitize: false, imageSource: transform)
    }

    /// Plain text of a body for MCP and previews: no markup, quoted history included as text.
    ///
    /// Text the reader would not show (`display:none`, `mso-hide:all`, `font-size:0`, the `hidden`
    /// attribute…) is left out: an assistant must read what the user sees, not instructions a
    /// sender tucked away for it.
    static func plainText(_ html: String?) -> String {
        guard let html, !html.isEmpty else { return "" }
        let visible = MailHTMLScanner.process(html, sanitize: true, dropHidden: true) { _ in nil }
        return MeetingBodyHTMLConverter.plainText(from: visible).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether a body shows nothing: no text (spaces, `&nbsp;` and zero-width characters do not
    /// count) and no images. Invitations often carry such a body; the reader then skips it rather
    /// than drawing an empty white frame.
    static func isVisuallyEmpty(_ html: String?) -> Bool {
        guard let html, !html.isEmpty else { return true }
        if html.range(of: "<(img|svg|video|hr)\\b", options: [.regularExpression, .caseInsensitive]) != nil { return false }
        let invisible = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{00A0}\u{200B}\u{200C}\u{200D}\u{FEFF}"))
        return plainText(html).trimmingCharacters(in: invisible).isEmpty
    }

    /// The host a link's visible text names, when it differs from where the link goes: the shape
    /// of a phishing link ("www.bank.com" pointing elsewhere).
    static func mismatchedLinkHost(text: String, url: URL) -> String? {
        guard let actualHost = url.host?.lowercased() else { return nil }
        let candidate = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let range = candidate.range(of: "^(https?://)?([a-z0-9-]+\\.)+[a-z]{2,}", options: .regularExpression) else { return nil }
        var shown = String(candidate[range])
        shown = shown.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
        let strip: (String) -> String = { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 }
        return strip(shown) == strip(actualHost) || strip(actualHost).hasSuffix("." + strip(shown)) ? nil : shown
    }
}

/// One pass over message markup, linear in its length.
///
/// Regular expressions are not used here on purpose: with backtracking, a hostile body (tens of
/// kilobytes of spaces, unterminated `<img` tags or quotes) made the old patterns run for
/// minutes on the main thread and froze the whole app. Nothing is rescanned: after a tag or quote
/// that never ends the rest is shown as escaped text; an unterminated comment or dropped element
/// (`<script>` never closed) hides the rest, as a browser would.
enum MailHTMLScanner {
    /// Elements dropped with everything inside them.
    static let droppedContainers: Set<String> = ["script", "iframe", "frameset", "object", "applet", "noscript", "noembed", "template"]
    /// Tags dropped on their own; their content (if any) stays.
    static let droppedTags: Set<String> = ["meta", "base", "link", "form", "input", "embed", "frame"]
    /// Attributes that can carry a URL a click or a load would follow.
    private static let urlAttributes: Set<String> = ["href", "src", "action", "formaction", "xlink:href", "background", "data", "poster", "srcset", "lowsrc", "dynsrc"]

    private typealias Scalars = [Unicode.Scalar]

    private struct Attribute {
        let name: String
        let range: Range<Int>
        let value: Range<Int>?
        let quote: Unicode.Scalar?
    }

    /// Elements without content: hiding one hides nothing after it.
    private static let voidElements: Set<String> = ["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr"]

    /// - Parameter zoomLink: for an image whose source `imageSource` replaced, the address of a
    ///   link to wrap it in (`nil`: none). Images already inside a sender's link are left alone:
    ///   anchors do not nest, and the sender's link would break.
    static func process(_ html: String, sanitize: Bool, dropHidden: Bool = false, imageSource: (String) -> String?, zoomLink: ((String) -> String?)? = nil) -> String {
        let s = Array(html.unicodeScalars)
        let n = s.count
        var out = String.UnicodeScalarView()
        out.reserveCapacity(n)
        var anchorDepth = 0
        var i = 0
        while i < n {
            guard let lt = index(of: "<", in: s, from: i) else {
                out.append(contentsOf: s[i..<n])
                break
            }
            out.append(contentsOf: s[i..<lt])
            if lt + 1 < n, s[lt + 1] == "!" {
                // Comments (Outlook keeps conditional markup in them) and the doctype stay as they are.
                let end = starts(s, at: lt, with: "<!--") ? find(s, "-->", from: lt + 4).map { $0 + 3 } : index(of: ">", in: s, from: lt).map { $0 + 1 }
                guard let end else { break }
                out.append(contentsOf: s[lt..<end])
                i = end
                continue
            }
            var j = lt + 1
            let closing = j < n && s[j] == "/"
            if closing { j += 1 }
            let nameStart = j
            while j < n, isNameScalar(s[j]) { j += 1 }
            guard j > nameStart else {
                out.append("<")
                i = lt + 1
                continue
            }
            let name = lowercased(s, nameStart..<j)
            guard let parsed = attributes(s, from: j) else {
                // A tag or quote that never ends (broken markup from some mailers): the rest is
                // shown as plain text rather than lost. Escaped, it is inert.
                if sanitize {
                    for scalar in s[lt..<n] {
                        switch scalar {
                        case "<": out.append(contentsOf: "&lt;".unicodeScalars)
                        case ">": out.append(contentsOf: "&gt;".unicodeScalars)
                        default: out.append(scalar)
                        }
                    }
                } else {
                    out.append(contentsOf: s[lt..<n])
                }
                break
            }
            let tagEnd = parsed.end + 1

            if sanitize, droppedContainers.contains(name) {
                if closing || parsed.selfClosing {
                    i = tagEnd
                } else if let close = closingTag(s, name: name, from: tagEnd), let gt = index(of: ">", in: s, from: close) {
                    i = gt + 1
                } else {
                    break  // never closed: everything after it was its content
                }
                continue
            }
            if sanitize, droppedTags.contains(name) {
                i = tagEnd
                continue
            }
            if closing {
                if name == "a" { anchorDepth = max(0, anchorDepth - 1) }
                out.append(contentsOf: s[lt..<tagEnd])
                i = tagEnd
                continue
            }
            if name == "a", !parsed.selfClosing { anchorDepth += 1 }
            if dropHidden, isHidden(parsed.list, in: s) {
                if parsed.selfClosing || voidElements.contains(name) {
                    i = tagEnd
                } else if let end = elementEnd(s, name: name, from: tagEnd) {
                    i = end
                } else {
                    break  // never closed: hidden to the end
                }
                continue
            }

            var rebuilt = false
            var parts: [String] = []
            // OWA puts its URL template (here a blank pixel) into `src` of an inline image and keeps
            // the `cid:` reference in `originalsrc`: that one is tried first.
            var originalReplacement: String?
            var matchedSource: String?
            if name == "img", let original = parsed.list.first(where: { $0.name == "originalsrc" })?.value {
                let source = unescaped(String(String.UnicodeScalarView(s[original])))
                originalReplacement = imageSource(source)
                if originalReplacement != nil { matchedSource = source }
            }
            var replacedSource = false
            for attribute in parsed.list {
                if sanitize, attribute.name.hasPrefix("on") || attribute.name == "ping" {
                    rebuilt = true
                    continue
                }
                if name == "img", attribute.name == "src", let value = attribute.value,
                   let replacement = originalReplacement ?? {
                       let source = unescaped(String(String.UnicodeScalarView(s[value])))
                       let replacement = imageSource(source)
                       if replacement != nil { matchedSource = source }
                       return replacement
                   }() {
                    let quote = attribute.quote.map(String.init) ?? "\""
                    parts.append(String(String.UnicodeScalarView(s[attribute.range.lowerBound..<value.lowerBound])).trimmingCharacters(in: .whitespaces)
                        .replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "'", with: "") + quote + replacement + quote)
                    rebuilt = true
                    replacedSource = true
                    continue
                }
                if sanitize, urlAttributes.contains(attribute.name), let value = attribute.value,
                   isScriptURL(String(String.UnicodeScalarView(s[value]))) {
                    let quote = attribute.quote.map(String.init) ?? "\""
                    parts.append(attribute.name + "=" + quote + "blocked:" + quote)
                    rebuilt = true
                    continue
                }
                parts.append(String(String.UnicodeScalarView(s[attribute.range])))
            }
            if let originalReplacement, !replacedSource, !parsed.list.contains(where: { $0.name == "src" }) {
                parts.append("src=\"" + originalReplacement + "\"")
                rebuilt = true
            }
            let zoomHref = anchorDepth == 0 ? matchedSource.flatMap { zoomLink?($0) } : nil
            if let zoomHref { out.append(contentsOf: "<a class=\"owaw-zoom\" href=\"\(zoomHref)\">".unicodeScalars) }
            if rebuilt {
                var tag = "<" + String(String.UnicodeScalarView(s[nameStart..<j]))
                for part in parts { tag += " " + part }
                if parsed.selfClosing { tag += " /" }
                out.append(contentsOf: (tag + ">").unicodeScalars)
            } else {
                out.append(contentsOf: s[lt..<tagEnd])
            }
            if zoomHref != nil { out.append(contentsOf: "</a>".unicodeScalars) }
            i = tagEnd
        }
        return String(out)
    }

    /// The attributes of a tag up to its `>`; `nil` when the tag or a quoted value never ends.
    private static func attributes(_ s: Scalars, from start: Int) -> (list: [Attribute], selfClosing: Bool, end: Int)? {
        let n = s.count
        var list: [Attribute] = []
        var selfClosing = false
        var k = start
        while k < n {
            let c = s[k]
            if c == ">" { return (list, selfClosing, k) }
            if isSpace(c) || c == "/" {
                selfClosing = c == "/"
                k += 1
                continue
            }
            selfClosing = false
            let attributeStart = k
            while k < n, !isSpace(s[k]), s[k] != "=", s[k] != ">", s[k] != "/" { k += 1 }
            let name = lowercased(s, attributeStart..<k)
            var m = k
            while m < n, isSpace(s[m]) { m += 1 }
            guard m < n, s[m] == "=" else {
                list.append(Attribute(name: name, range: attributeStart..<k, value: nil, quote: nil))
                continue
            }
            m += 1
            while m < n, isSpace(s[m]) { m += 1 }
            if m < n, s[m] == "\"" || s[m] == "'" {
                let quote = s[m]
                guard let close = index(of: quote, in: s, from: m + 1) else { return nil }
                list.append(Attribute(name: name, range: attributeStart..<(close + 1), value: (m + 1)..<close, quote: quote))
                k = close + 1
            } else {
                let valueStart = m
                while m < n, !isSpace(s[m]), s[m] != ">" { m += 1 }
                list.append(Attribute(name: name, range: attributeStart..<m, value: valueStart..<m, quote: nil))
                k = m
            }
        }
        return nil
    }

    /// Hidden by attribute or inline style, the ways mail hides text from a reader.
    private static func isHidden(_ attributes: [Attribute], in s: Scalars) -> Bool {
        for attribute in attributes {
            if attribute.name == "hidden" { return true }
            guard attribute.name == "style", let value = attribute.value else { continue }
            var compact = ""
            for i in value where !isSpace(s[i]) { compact.unicodeScalars.append(lowercase(s[i])) }
            if compact.contains("display:none") || compact.contains("visibility:hidden") || compact.contains("mso-hide:all") {
                return true
            }
            for property in ["font-size:0", "opacity:0"] {
                var searchStart = compact.startIndex
                while let range = compact.range(of: property, range: searchStart..<compact.endIndex) {
                    let next = range.upperBound < compact.endIndex ? compact[range.upperBound] : ";"
                    if !(next.isNumber || next == ".") { return true }
                    searchStart = range.upperBound
                }
            }
        }
        return false
    }

    /// Just past the tag that closes this element, counting nested elements of the same name.
    private static func elementEnd(_ s: Scalars, name: String, from start: Int) -> Int? {
        let target = Array(name.unicodeScalars)
        var depth = 1
        var i = start
        while let lt = index(of: "<", in: s, from: i) {
            let closing = lt + 1 < s.count && s[lt + 1] == "/"
            let nameStart = lt + (closing ? 2 : 1)
            var matches = nameStart + target.count <= s.count
            if matches {
                for (offset, scalar) in target.enumerated() where lowercase(s[nameStart + offset]) != scalar {
                    matches = false
                    break
                }
            }
            let after = nameStart + target.count
            if matches, after >= s.count || !isNameScalar(s[after]) {
                guard let gt = index(of: ">", in: s, from: after) else { return nil }
                if closing {
                    depth -= 1
                    if depth == 0 { return gt + 1 }
                } else if s[gt - 1] != "/" {
                    depth += 1
                }
                i = gt + 1
            } else {
                i = lt + 1
            }
        }
        return nil
    }

    /// `javascript:` / `vbscript:` however written: entities, case, whitespace and control
    /// characters inside the scheme.
    private static func isScriptURL(_ raw: String) -> Bool {
        var text = unescaped(raw)
        text = text.replacingOccurrences(of: "&colon;", with: ":", options: .caseInsensitive)
        var compact = String.UnicodeScalarView()
        for scalar in decodeNumericEntities(text).unicodeScalars where scalar.value > 0x20 && !(0x7F...0x9F).contains(scalar.value) {
            compact.append(scalar)
            if compact.count > 16 { break }
        }
        let head = String(compact).lowercased()
        return head.hasPrefix("javascript:") || head.hasPrefix("vbscript:") || head.hasPrefix("livescript:")
    }

    /// `&#106;` and `&#x6A;` (with or without the semicolon), only in the short scheme part.
    private static func decodeNumericEntities(_ text: String) -> String {
        guard text.contains("&#") else { return text }
        let scalars = Array(text.unicodeScalars.prefix(200))
        var out = String.UnicodeScalarView()
        var i = 0
        while i < scalars.count {
            if scalars[i] == "&", i + 1 < scalars.count, scalars[i + 1] == "#" {
                var j = i + 2
                let hex = j < scalars.count && (scalars[j] == "x" || scalars[j] == "X")
                if hex { j += 1 }
                var value: UInt32 = 0
                let digitsStart = j
                while j < scalars.count, j - digitsStart < 8, let digit = Int(String(scalars[j]), radix: hex ? 16 : 10) {
                    value = value &* (hex ? 16 : 10) &+ UInt32(digit)
                    j += 1
                }
                if j > digitsStart, let scalar = Unicode.Scalar(value) {
                    out.append(scalar)
                    if j < scalars.count, scalars[j] == ";" { j += 1 }
                    i = j
                    continue
                }
            }
            out.append(scalars[i])
            i += 1
        }
        return String(out)
    }

    static func unescaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
    }

    /// The `</name` that closes a dropped element, case-insensitive.
    private static func closingTag(_ s: Scalars, name: String, from start: Int) -> Int? {
        let target = Array(name.unicodeScalars)
        var i = start
        while let lt = index(of: "<", in: s, from: i) {
            if lt + 1 < s.count, s[lt + 1] == "/" {
                var matches = lt + 2 + target.count <= s.count
                if matches {
                    for (offset, scalar) in target.enumerated() where lowercase(s[lt + 2 + offset]) != scalar {
                        matches = false
                        break
                    }
                }
                let after = lt + 2 + target.count
                if matches, after >= s.count || !isNameScalar(s[after]) { return lt }
            }
            i = lt + 1
        }
        return nil
    }

    private static func index(of scalar: Unicode.Scalar, in s: Scalars, from start: Int) -> Int? {
        var i = start
        while i < s.count {
            if s[i] == scalar { return i }
            i += 1
        }
        return nil
    }

    private static func find(_ s: Scalars, _ needle: String, from start: Int) -> Int? {
        let target = Array(needle.unicodeScalars)
        guard let first = target.first else { return nil }
        var i = start
        while let candidate = index(of: first, in: s, from: i) {
            if starts(s, at: candidate, with: needle) { return candidate }
            i = candidate + 1
        }
        return nil
    }

    private static func starts(_ s: Scalars, at index: Int, with prefix: String) -> Bool {
        var i = index
        for scalar in prefix.unicodeScalars {
            guard i < s.count, s[i] == scalar else { return false }
            i += 1
        }
        return true
    }

    private static func isNameScalar(_ c: Unicode.Scalar) -> Bool {
        (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || (c >= "0" && c <= "9") || c == "-" || c == ":"
    }

    private static func isSpace(_ c: Unicode.Scalar) -> Bool {
        c == " " || c == "\t" || c == "\n" || c == "\r" || c == "\u{0C}"
    }

    private static func lowercase(_ c: Unicode.Scalar) -> Unicode.Scalar {
        (c >= "A" && c <= "Z") ? Unicode.Scalar(c.value + 32)! : c
    }

    private static func lowercased(_ s: Scalars, _ range: Range<Int>) -> String {
        var view = String.UnicodeScalarView()
        for i in range { view.append(lowercase(s[i])) }
        return String(view)
    }
}
