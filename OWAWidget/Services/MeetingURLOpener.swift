import AppKit
import os.log

/// Centralized, scheme-validating opener for meeting "join" links.
///
/// Meeting URLs originate from server-controlled calendar data, so a crafted invite
/// could carry a dangerous scheme (`file://`, custom app schemes, etc.). This opener
/// only ever launches `https` URLs:
///   - `https`      → opened as-is
///   - missing      → normalized to `https` (legitimate protocol-less links keep working)
///   - `http`       → upgraded to `https`
///   - anything else → refused
enum MeetingURLOpener {
    private static let log = Logger(subsystem: "com.owawidget", category: "MeetingURLOpener")

    /// Returns an `https` URL safe to open, or `nil` if the input uses a disallowed scheme.
    static func safeURL(from url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased() else {
            // No scheme — treat the whole string as an https host/path.
            return normalizedHTTPS(from: url.absoluteString)
        }
        switch scheme {
        case "https": return url
        case "http":  return normalizedHTTPS(from: url.absoluteString)
        default:      return nil
        }
    }

    static func safeURL(fromString string: String) -> URL? {
        guard let url = URL(string: string) else { return nil }
        return safeURL(from: url)
    }

    /// Opens the URL if it resolves to a safe `https` URL. Returns `true` on success.
    /// Callers should gate side effects (engagement tracking, dismiss UI) on the result.
    @discardableResult
    static func open(_ url: URL) -> Bool {
        guard let safe = safeURL(from: url) else {
            log.warning("Refused to open meeting URL with disallowed scheme: \(url.scheme ?? "nil", privacy: .public)")
            return false
        }
        return NSWorkspace.shared.open(safe)
    }

    private static func normalizedHTTPS(from raw: String) -> URL? {
        var string = raw
        if string.lowercased().hasPrefix("http://") {
            string = String(string.dropFirst("http://".count))
        }
        if !string.lowercased().hasPrefix("https://") {
            string = "https://" + string
        }
        guard let url = URL(string: string), let host = url.host, !host.isEmpty else { return nil }
        return url
    }
}
