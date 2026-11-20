import Foundation

/// A link into the app (`owawidget://…`), for a notification or a note to open the mail window.
///
/// Links only show things: none of them sends, drafts, moves or deletes. Any app or web page can
/// open one, so everything not on the lists below is refused rather than guessed at.
enum AppURLRoute: Equatable, Sendable {
    /// The mail window, brought to the front.
    case mail
    /// A conversation in the mail window.
    case thread(id: String, accountID: UUID?)
    /// The conversation of one message, with that message unfolded and scrolled to.
    case message(id: String, accountID: UUID?)

    /// The release build's scheme. A development build (`make run`, bundle id `….dev`) registers
    /// `owawidget-dev`, so a Mac with both copies does not hand links to a random one.
    static let releaseScheme = "owawidget"
    static let developmentScheme = "owawidget-dev"
    static let schemes: Set<String> = [releaseScheme, developmentScheme]

    /// Exchange ids are base64 (about 150 characters); the MCP server's short handles are 12 hex.
    static let maxIDLength = 512
    private static let idCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=-_")

    static func parse(_ url: URL) -> AppURLRoute? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(), schemes.contains(scheme),
              components.user == nil, components.password == nil, components.port == nil,
              components.path.isEmpty || components.path == "/",
              let host = components.host?.lowercased() else { return nil }
        // Repeated parameters are ambiguous: refuse them rather than pick one.
        let items = components.queryItems ?? []
        func value(_ name: String) -> String?? {
            let matches = items.filter { $0.name == name }
            guard matches.count <= 1 else { return .some(nil) }
            return matches.first.map { $0.value }
        }
        switch host {
        case "mail":
            return .mail
        case "thread", "message":
            guard case .some(.some(let id)) = value("id"), isValidID(id) else { return nil }
            var accountID: UUID?
            switch value("account") {
            case .none: break
            case .some(.some(let raw)):
                guard let parsed = UUID(uuidString: raw) else { return nil }
                accountID = parsed
            case .some(.none): return nil
            }
            return host == "thread" ? .thread(id: id, accountID: accountID) : .message(id: id, accountID: accountID)
        default:
            return nil
        }
    }

    static func isValidID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= maxIDLength && id.unicodeScalars.allSatisfy { idCharacters.contains($0) }
    }

    /// Whether `id` is an MCP short handle rather than a full Exchange id (the MCP server accepts
    /// anything longer than 20 characters as a full id).
    static func isShortHandle(_ id: String) -> Bool { id.count <= 20 }

    /// The link for this route. Query values are encoded strictly: Exchange ids carry `+`, `/`
    /// and `=`, which a query would otherwise read as a space or a separator.
    func url(scheme: String = AppURLRoute.currentScheme) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        let query: [(String, String)]
        switch self {
        case .mail:
            components.host = "mail"
            query = []
        case .thread(let id, let accountID):
            components.host = "thread"
            query = [("id", id)] + (accountID.map { [("account", $0.uuidString)] } ?? [])
        case .message(let id, let accountID):
            components.host = "message"
            query = [("id", id)] + (accountID.map { [("account", $0.uuidString)] } ?? [])
        }
        if !query.isEmpty {
            components.percentEncodedQuery = query
                .map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: Self.unreserved) ?? $0.1)" }
                .joined(separator: "&")
        }
        return components.url
    }

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// The scheme this copy of the app registers (from its Info.plist): links handed out must open
    /// this copy, not another one on the same Mac. Outside an app bundle (tests) the release scheme.
    static var currentScheme: String {
        scheme(fromInfo: Bundle.main.infoDictionary)
    }

    static func scheme(fromInfo info: [String: Any]?) -> String {
        guard let types = info?["CFBundleURLTypes"] as? [[String: Any]] else { return releaseScheme }
        for type in types {
            if let schemes = type["CFBundleURLSchemes"] as? [String],
               let scheme = schemes.first(where: { Self.schemes.contains($0.lowercased()) }) {
                return scheme.lowercased()
            }
        }
        return releaseScheme
    }
}
