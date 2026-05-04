import Foundation
import os.log

// Captures Set-Cookie headers from redirect responses and TLS challenges.
private final class OWASessionDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _cookies: [HTTPCookie] = []
    private var _redirectChain: [String] = []

    var allCookies: [HTTPCookie]    { lock.lock(); defer { lock.unlock() }; return _cookies }
    var redirectChain: [String]     { lock.lock(); defer { lock.unlock() }; return _redirectChain }

    func reset() { lock.lock(); _cookies = []; _redirectChain = []; lock.unlock() }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        if let from = response.url?.path, let to = request.url?.absoluteString {
            lock.lock()
            _redirectChain.append("\(response.statusCode) \(from) → \(to)")
            lock.unlock()
        }
        if let headers = response.allHeaderFields as? [String: String], let url = response.url {
            let cookies = HTTPCookie.cookies(withResponseHeaderFields: headers, for: url)
            lock.lock()
            _cookies.append(contentsOf: cookies)
            lock.unlock()
        }
        completionHandler(request)
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

actor OWAClient {
    private let baseURL: URL
    private let username: String
    private let password: String

    private var canaryToken: String?
    private let sessionDelegate: OWASessionDelegate
    private let session: URLSession
    private let log = Logger(subsystem: "com.owawidget", category: "OWAClient")

    init(serverURL: String, username: String, password: String) throws {
        self.baseURL = try Self.parseBaseURL(serverURL)
        self.username = username
        self.password = password

        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        config.timeoutIntervalForRequest = 30

        let delegate = OWASessionDelegate()
        self.sessionDelegate = delegate
        self.session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    // MARK: - Auth

    func authenticate() async throws {
        sessionDelegate.reset()

        // 1. Скачиваем страницу логина, получаем action и скрытые поля формы
        let loginForm = await fetchLoginForm()
        log.debug("Login form action: \(loginForm.action), fields: \(loginForm.hiddenFields.map(\.0))")

        // 2. POST — отправляем ровно то, что в форме + логин/пароль
        let (authData, authResponse) = try await submitAuthForm(form: loginForm)
        let authFinalURL = authResponse.url?.absoluteString ?? "nil"
        log.debug("Auth final URL: \(authFinalURL), status: \(authResponse.statusCode)")
        log.debug("Redirects: \(self.sessionDelegate.redirectChain)")

        // 3. Extract CANARY from cookies captured in redirect chain
        let delegateCookies = sessionDelegate.allCookies
        log.debug("Delegate cookies: \(delegateCookies.map(\.name))")
        canaryToken = delegateCookies.first(where: { $0.name == "X-OWA-CANARY" })?.value

        // 4. Try session's own storage as fallback
        if canaryToken == nil {
            let stored = session.configuration.httpCookieStorage?.cookies ?? []
            canaryToken = stored.first(where: { $0.name == "X-OWA-CANARY" })?.value
        }

        // 5. Try extracting CANARY from auth response HTML
        if canaryToken == nil, let html = String(data: authData, encoding: .utf8) {
            canaryToken = extractCanaryFromHTML(html)
        }

        // 6. GET /owa/ as authenticated user — CANARY should be in the page HTML
        if canaryToken == nil {
            try await fetchCanaryFromOWAPage()
        }

        guard canaryToken != nil else {
            let bodyPreview = String(data: authData.prefix(500), encoding: .utf8)?
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: "")
                .trimmingCharacters(in: .whitespaces)
                .prefix(300)
            throw OWAError.authenticationFailed(
                "No CANARY. " +
                "FormAction: \(loginForm.action). " +
                "AuthURL: \(authFinalURL) (HTTP \(authResponse.statusCode)). " +
                "Redirects: \(sessionDelegate.redirectChain.joined(separator: "|")). " +
                "Cookies: \(delegateCookies.map(\.name)). " +
                "AuthBody[\(authData.count)]: \(bodyPreview ?? "?")"
            )
        }
        log.info("OWA auth OK for \(self.baseURL.host ?? "")")
    }

    // MARK: - Login form

    private struct LoginForm {
        var action: String          // абсолютный URL для POST
        var hiddenFields: [(String, String)]  // name → value из <input type="hidden">
        var referer: String         // URL страницы логина
    }

    /// Скачивает страницу /owa/, следует редиректу на logon.aspx,
    /// парсит форму и возвращает все нужные для POST данные.
    private func fetchLoginForm() async -> LoginForm {
        var req = URLRequest(url: url("/owa/"))
        addCommonHeaders(&req)

        let fallback = LoginForm(
            action: url("/owa/auth.owa").absoluteString,
            hiddenFields: [
                ("destination",    url("/owa/?bFS=1").absoluteString),
                ("flags",          "4"),
                ("forcedownlevel", "0"),
                ("isUtf8",         "1"),
            ],
            referer: url("/owa/auth/logon.aspx").absoluteString
        )

        guard let (data, resp) = try? await session.data(for: req),
              let http = resp as? HTTPURLResponse,
              let pageURL = http.url,
              let html = String(data: data, encoding: .utf8) else {
            return fallback
        }

        let referer = pageURL.absoluteString

        // Извлекаем action из <form … action="…">
        var actionURL = url("/owa/auth.owa").absoluteString
        if let re = try? NSRegularExpression(pattern: #"<form[^>]+action="([^"]+)""#, options: .caseInsensitive) {
            let ns = html as NSString
            if let m = re.firstMatch(in: html, range: NSRange(location: 0, length: ns.length)),
               m.numberOfRanges > 1 {
                let raw = ns.substring(with: m.range(at: 1))
                // Может быть относительным URL
                if raw.hasPrefix("http") {
                    actionURL = raw
                } else if let base = URL(string: raw, relativeTo: pageURL) {
                    actionURL = base.absoluteURL.absoluteString
                }
            }
        }

        // Извлекаем все <input type="hidden" name="…" value="…">
        var hiddenFields: [(String, String)] = []
        if let re = try? NSRegularExpression(
            pattern: #"<input[^>]+type="hidden"[^>]+name="([^"]*)"[^>]+value="([^"]*)""#,
            options: .caseInsensitive
        ) {
            let ns = html as NSString
            let matches = re.matches(in: html, range: NSRange(location: 0, length: ns.length))
            for m in matches where m.numberOfRanges > 2 {
                let name  = ns.substring(with: m.range(at: 1))
                let value = ns.substring(with: m.range(at: 2))
                hiddenFields.append((name, value))
            }
        }
        // Обратный порядок атрибутов name/value тоже встречается
        if hiddenFields.isEmpty,
           let re = try? NSRegularExpression(
            pattern: #"<input[^>]+type="hidden"[^>]+value="([^"]*)"[^>]+name="([^"]*)""#,
            options: .caseInsensitive
           ) {
            let ns = html as NSString
            let matches = re.matches(in: html, range: NSRange(location: 0, length: ns.length))
            for m in matches where m.numberOfRanges > 2 {
                let value = ns.substring(with: m.range(at: 1))
                let name  = ns.substring(with: m.range(at: 2))
                hiddenFields.append((name, value))
            }
        }

        // Если форма пустая — возвращаем fallback-набор полей
        if hiddenFields.isEmpty { hiddenFields = fallback.hiddenFields }

        log.debug("Parsed form: action=\(actionURL), fields=\(hiddenFields.map { "\($0.0)=\($0.1)" })")
        return LoginForm(action: actionURL, hiddenFields: hiddenFields, referer: referer)
    }

    private func submitAuthForm(form: LoginForm) async throws -> (Data, HTTPURLResponse) {
        guard let authURL = URL(string: form.action) else { throw OWAError.invalidURL(form.action) }

        var request = URLRequest(url: authURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(form.referer, forHTTPHeaderField: "Referer")
        request.setValue(baseURL.absoluteString, forHTTPHeaderField: "Origin")
        addCommonHeaders(&request)

        // Скрытые поля из формы + учётные данные в конце
        var params = form.hiddenFields
        // Убираем дублирующиеся поля из формы, которые мы переопределяем
        params.removeAll { ["username","password","passwd","passwordText"].contains($0.0) }
        params.append(("username",      username))
        params.append(("password",      password))
        params.append(("passwordText",  ""))

        request.httpBody = params
            .map { "\($0.0)=\($0.1.formEncoded)" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OWAError.invalidResponse }
        return (data, http)
    }

    private func fetchCanaryFromOWAPage() async throws {
        var req = URLRequest(url: url("/owa/"))
        addCommonHeaders(&req)
        let (data, _) = try await session.data(for: req)
        if let html = String(data: data, encoding: .utf8) {
            canaryToken = extractCanaryFromHTML(html)
        }
    }

    // MARK: - Calendar view

    func fetchCalendarView(from start: Date, to end: Date) async throws -> [OWACalendarItem] {
        if canaryToken == nil { try await authenticate() }
        do {
            return try await performCalendarViewRequest(from: start, to: end)
        } catch OWAError.httpError(440, _), OWAError.httpError(401, _) {
            canaryToken = nil
            try await authenticate()
            return try await performCalendarViewRequest(from: start, to: end)
        }
    }

    private func performCalendarViewRequest(from start: Date, to end: Date) async throws -> [OWACalendarItem] {
        guard let canary = canaryToken else { throw OWAError.notAuthenticated }

        var components = URLComponents(url: url("/owa/service.svc"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "action", value: "GetCalendarView")]
        guard let serviceURL = components.url else { throw OWAError.invalidURL("/owa/service.svc") }

        let localFmt = localDateFormatter()
        let requestDict: [String: Any] = [
            "__type": "GetCalendarViewJsonRequest:#Exchange",
            "Header": [
                "__type": "JsonRequestHeaders:#Exchange",
                "RequestServerVersion": "V2017_08_18",
                "TimeZoneContext": [
                    "__type": "TimeZoneContext:#Exchange",
                    "TimeZoneDefinition": [
                        "__type": "TimeZoneDefinitionType:#Exchange",
                        "Id": windowsTimezoneID(),
                    ] as [String: Any],
                ] as [String: Any],
            ] as [String: Any],
            "Body": [
                "__type": "GetCalendarViewRequest:#Exchange",
                "CalendarId": [
                    "__type": "TargetFolderId:#Exchange",
                    "BaseFolderId": [
                        "__type": "DistinguishedFolderId:#Exchange",
                        "Id": "calendar",
                    ] as [String: Any],
                ] as [String: Any],
                "RangeStart": localFmt.string(from: start),
                "RangeEnd":   localFmt.string(from: end),
            ] as [String: Any],
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: requestDict)
        guard let jsonString = String(data: jsonData, encoding: .utf8) else { throw OWAError.encodingFailed }

        var request = URLRequest(url: serviceURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(canary, forHTTPHeaderField: "X-OWA-CANARY")
        request.setValue("GetCalendarView", forHTTPHeaderField: "Action")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue(jsonString.formEncoded, forHTTPHeaderField: "X-OWA-UrlPostData")
        request.httpBody = Data()
        addCommonHeaders(&request)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OWAError.invalidResponse }

        guard (200..<300).contains(http.statusCode) else {
            let msg = String(data: data.prefix(300), encoding: .utf8) ?? ""
            throw OWAError.httpError(http.statusCode, msg)
        }

        return (try JSONDecoder().decode(OWAServiceResponse.self, from: data)).Body?.Items ?? []
    }

    // MARK: - Helpers

    private func url(_ path: String) -> URL {
        URL(string: baseURL.absoluteString + path)!
    }

    private func addCommonHeaders(_ request: inout URLRequest) {
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("text/html,application/json,*/*;q=0.9", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
    }

    private func extractCanaryFromHTML(_ html: String) -> String? {
        let patterns = [
            #""canary"\s*:\s*"([^"]+)""#,
            #"name="canary"\s+value="([^"]+)""#,
            #"name="canary" content="([^"]+)""#,
            #"var\s+g_canary\s*=\s*"([^"]+)""#,
            #"X-OWA-CANARY[^"]*"\s*,\s*"([^"]+)""#,
            #"data-canary="([^"]+)""#,
            #"canary:\s*'([^']+)'"#,
        ]
        for pattern in patterns {
            guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            let ns = html as NSString
            guard let match = re.firstMatch(in: html, range: NSRange(location: 0, length: ns.length)),
                  match.numberOfRanges > 1 else { continue }
            let r = match.range(at: 1)
            guard r.location != NSNotFound else { continue }
            let value = ns.substring(with: r)
            log.info("CANARY found via pattern: \(pattern)")
            return value
        }
        return nil
    }

    private func localDateFormatter() -> DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        return f
    }

    private func windowsTimezoneID() -> String {
        let mapping: [String: String] = [
            "Europe/Moscow":       "Russian Standard Time",
            "Europe/Samara":       "Russia Time Zone 3",
            "Asia/Yekaterinburg":  "Ekaterinburg Standard Time",
            "Europe/London":       "GMT Standard Time",
            "America/New_York":    "Eastern Standard Time",
            "America/Chicago":     "Central Standard Time",
            "America/Denver":      "Mountain Standard Time",
            "America/Los_Angeles": "Pacific Standard Time",
            "Europe/Berlin":       "W. Europe Standard Time",
            "Europe/Paris":        "Romance Standard Time",
            "Asia/Tokyo":          "Tokyo Standard Time",
        ]
        return mapping[TimeZone.current.identifier] ?? "Russian Standard Time"
    }

    static func parseBaseURL(_ input: String) throws -> URL {
        var cleaned = input.trimmingCharacters(in: .whitespaces)
        if !cleaned.lowercased().hasPrefix("http://") && !cleaned.lowercased().hasPrefix("https://") {
            cleaned = "https://" + cleaned
        }
        guard let parsed = URL(string: cleaned), let host = parsed.host else {
            throw OWAError.invalidURL(input)
        }
        let scheme = parsed.scheme ?? "https"
        let port   = parsed.port.map { ":\($0)" } ?? ""
        guard let base = URL(string: "\(scheme)://\(host)\(port)") else {
            throw OWAError.invalidURL(input)
        }
        return base
    }
}

private extension String {
    var formEncoded: String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }
}
