import Foundation

/// Wraps a message body (HTML the server already filtered) into the document the reader loads.
///
/// The reader is locked down independently of the server's filtering: the document carries a
/// Content-Security-Policy that allows nothing but inline styles and `data:` images and fonts, the
/// web view runs no script and blocks every network load, and navigation is intercepted. So a
/// tracking pixel, a remote stylesheet or a form never reaches the network from here.
enum MailHTMLDocument {
    static let contentSecurityPolicy = "default-src 'none'; img-src data:; style-src 'unsafe-inline'; font-src data:; form-action 'none'; frame-src 'none'; base-uri 'none'"

    /// Elements that have no business in a message shown here; their whole content goes.
    private static let droppedElements = ["script", "iframe", "frame", "frameset", "object", "embed", "applet", "form", "noscript"]
    /// Void or head-only elements that could redirect, re-base or pull in content.
    private static let droppedTags = ["meta", "base", "link"]

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
        var html = sanitized(body)
        html = replacingImageSources(in: html) { source in
            if let cid = contentID(fromSource: source), let image = inlineImages[cid] ?? inlineImages[cid.lowercased()] {
                return dataURI(image.data, type: image.type)
            }
            if let image = remoteImages[source] {
                return dataURI(image.data, type: image.type)
            }
            return nil
        }
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
        table { max-width: 100% !important; }
        pre { white-space: pre-wrap; }
        /* Generated mail often zeroes list padding; the bullets would hang outside the page. */
        #owaw-root ul, #owaw-root ol { padding-inline-start: 1.6em !important; }
        blockquote { margin-left: 0; padding-left: 10px; border-left: 2px solid #d0d0d5; color: #555; }
        a { color: #0a66d6; }
        #owaw-root { display: flow-root; padding: 12px 14px; box-sizing: border-box; }
        /* Remote images stay blocked: show a quiet placeholder instead of an empty frame. */
        img[src^="http"], img[src^="HTTP"] { background: #f2f2f4 url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='16' height='16' viewBox='0 0 24 24' fill='none' stroke='%23a0a0a8' stroke-width='2'%3E%3Crect x='3' y='4' width='18' height='16' rx='2'/%3E%3Ccircle cx='9' cy='10' r='2'/%3E%3Cpath d='m21 17-5-5-9 8'/%3E%3C/svg%3E") center no-repeat; min-width: 20px; min-height: 20px; outline: 1px dashed #d4d4da; outline-offset: -1px; color: transparent; }
        </style></head>
        <body><div id="owaw-root">\(html)</div></body></html>
        """
    }

    /// Removes active and redirecting markup. Defense in depth: the server filters too, and the
    /// web view runs no script, but a document that never contains them cannot surprise anyone.
    static func sanitized(_ html: String) -> String {
        var text = html
        for element in droppedElements {
            text = text.replacingOccurrences(
                of: "<\(element)\\b[^>]*>[\\s\\S]*?</\(element)\\s*>",
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
            text = text.replacingOccurrences(of: "<\(element)\\b[^>]*/?>", with: "", options: [.regularExpression, .caseInsensitive])
        }
        for tag in droppedTags {
            text = text.replacingOccurrences(of: "<\(tag)\\b[^>]*>", with: "", options: [.regularExpression, .caseInsensitive])
        }
        // Inline event handlers (onclick=, onload=...) and javascript: URLs.
        text = text.replacingOccurrences(
            of: "\\s+on[a-z]+\\s*=\\s*(\"[^\"]*\"|'[^']*'|[^\\s>]+)",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        text = text.replacingOccurrences(of: "javascript:", with: "blocked:", options: .caseInsensitive)
        return text
    }

    /// `cid:abc@01D` → `abc@01D`.
    static func contentID(fromSource source: String) -> String? {
        let trimmed = source.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("cid:") else { return nil }
        let value = String(trimmed.dropFirst(4)).removingPercentEncoding ?? String(trimmed.dropFirst(4))
        return value.isEmpty ? nil : value
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

    /// Whether a body references images the reader blocked (`http(s)` sources).
    static func hasRemoteImages(_ html: String) -> Bool {
        !remoteImageSources(in: html).isEmpty
    }

    /// Rewrites every `<img src="…">` through `transform`; `nil` keeps the source.
    static func replacingImageSources(in html: String, transform: (String) -> String?) -> String {
        guard let regex = try? NSRegularExpression(pattern: "(<img\\b[^>]*?\\bsrc\\s*=\\s*)([\"'])(.*?)\\2", options: [.caseInsensitive]) else {
            return html
        }
        let ns = html as NSString
        var output = ""
        var cursor = 0
        for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let sourceRange = match.range(at: 3)
            output += ns.substring(with: NSRange(location: cursor, length: sourceRange.location - cursor))
            let source = ns.substring(with: sourceRange)
            output += transform(htmlUnescaped(source)) ?? source
            cursor = sourceRange.location + sourceRange.length
        }
        output += ns.substring(from: cursor)
        return output
    }

    private static func htmlUnescaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
    }

    /// Plain text of a body for MCP and previews: no markup, quoted history included as text.
    static func plainText(_ html: String?) -> String {
        guard let html, !html.isEmpty else { return "" }
        return MeetingBodyHTMLConverter.plainText(from: sanitized(html)).trimmingCharacters(in: .whitespacesAndNewlines)
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
