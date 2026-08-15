import Foundation
import os.log

// Captures Set-Cookie headers from redirect responses and TLS challenges.
private final class OWASessionDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _cookies: [HTTPCookie] = []
    private var _redirectChain: [String] = []
    private var _pendingUntrusted: (host: String, port: Int, fingerprint: String)?
    private var _authRejected = false

    /// Credentials for Integrated Windows Auth (NTLM/Negotiate). Username is expected in
    /// `DOMAIN\login` form (e.g. `MOSCOW\U_12345`).
    private let username: String
    private let password: String

    init(username: String, password: String) {
        self.username = username
        self.password = password
        super.init()
    }

    var allCookies: [HTTPCookie]    { lock.lock(); defer { lock.unlock() }; return _cookies }
    var redirectChain: [String]     { lock.lock(); defer { lock.unlock() }; return _redirectChain }

    func reset() { lock.lock(); _cookies = []; _redirectChain = []; _pendingUntrusted = nil; _authRejected = false; lock.unlock() }

    /// Returns and clears whether the last cancelled request was cancelled because the NTLM/
    /// Negotiate handshake declined our credentials (a confirmed wrong-password), as opposed to
    /// an ordinary task cancellation — both surface as `NSURLErrorCancelled` (-999), so the flag
    /// is the only way to tell them apart.
    func takeAuthRejected() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let value = _authRejected
        _authRejected = false
        return value
    }

    /// Returns and clears the most recent rejected (untrusted) certificate, if any.
    /// Set when the server presented a certificate that failed system validation and
    /// was not in the user's manual trust store.
    func takePendingUntrusted() -> (host: String, port: Int, fingerprint: String)? {
        lock.lock(); defer { lock.unlock() }
        let value = _pendingUntrusted
        _pendingUntrusted = nil
        return value
    }

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

        // Still follow the redirect (federated/ADFS login depends on it), but never carry
        // the Authorization header across a host change to avoid leaking credentials.
        var forwarded = request
        if let fromHost = response.url?.host?.lowercased(),
           let toHost = request.url?.host?.lowercased(),
           fromHost != toHost {
            forwarded.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        completionHandler(forwarded)
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let method = challenge.protectionSpace.authenticationMethod

        // Integrated Windows Auth. OWA moved to SSO, so the server now answers every request with
        // `401 WWW-Authenticate: Negotiate, NTLM` instead of a forms-login page.
        //
        // URLSession always tries the *first* offered method (Negotiate / Kerberos-SPNEGO) and,
        // given a username+password, never falls back to NTLM on its own. Over CheckPoint VPN
        // there is no Kerberos ticket / reachable KDC, so Negotiate always fails and the whole
        // request dies. We therefore explicitly *reject* the Negotiate protection space, which
        // makes URLSession re-challenge with the next offered method — NTLM — where a plain
        // DOMAIN\login + password works.
        if method == NSURLAuthenticationMethodNegotiate {
            // NSURLSessionAuthChallengeRejectProtectionSpace (== 3). Not surfaced as a named Swift
            // case in this SDK, so build it from the raw value. "Reject this protection space and
            // continue with the next authentication method for this request."
            completionHandler(URLSession.AuthChallengeDisposition(rawValue: 3) ?? .performDefaultHandling, nil)
            return
        }
        if method == NSURLAuthenticationMethodNTLM {
            // Offer the credential exactly once. A repeat challenge for the same request
            // (previousFailureCount > 0) means the server rejected it. Cancel and flag it so the
            // client maps the resulting `NSURLErrorCancelled` to a definitive wrong-password error.
            guard challenge.previousFailureCount == 0, !username.isEmpty else {
                lock.lock(); _authRejected = true; lock.unlock()
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            completionHandler(
                .useCredential,
                URLCredential(user: username, password: password, persistence: .forSession)
            )
            return
        }

        guard method == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        // 1. Strict system evaluation (valid chain + hostname).
        var evalError: CFError?
        if SecTrustEvaluateWithError(trust, &evalError) {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }

        // 2. System rejected — accept only if the user explicitly trusted this exact
        //    certificate for this host (manual pin for self-signed / internal-CA servers).
        let storeKey = TrustedCertificateStore.key(
            host: challenge.protectionSpace.host,
            port: challenge.protectionSpace.port
        )
        let fingerprint = TrustedCertificateStore.leafFingerprint(from: trust)
        if let fingerprint, TrustedCertificateStore.isTrusted(fingerprint: fingerprint, forKey: storeKey) {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }

        // 3. Untrusted — record for the UI ("trust this server?") and refuse.
        if let fingerprint {
            lock.lock()
            _pendingUntrusted = (
                host: challenge.protectionSpace.host,
                port: challenge.protectionSpace.port,
                fingerprint: fingerprint
            )
            lock.unlock()
        }
        completionHandler(.cancelAuthenticationChallenge, nil)
    }
}

actor OWAClient {
    private let baseURL: URL
    private let username: String
    private let password: String

    private var canaryToken: String?
    private var defaultCalendarFolderIdentifier: OWAFolderIdentifier?
    private var forceDistinguishedCalendarFolder = false
    private var requestSequence = 0
    private var cachedOrganizerSMTPEmail: String?
    private let sessionDelegate: OWASessionDelegate
    private let session: URLSession
    private let log = Logger(subsystem: "com.owawidget", category: "OWAClient")
    #if DEBUG
    private let getCalendarViewDebugFlagKey = "debugDumpGetCalendarViewResponse"
    #endif

    #if DEBUG
    private static let debugLogName = "owaclient.log"

    private nonisolated func setupDebugLog() {
        DebugLogLocation.write("=== OWAClient Log started \(Date()) ===\n", to: Self.debugLogName)
    }

    private nonisolated func dlog(_ message: String) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        DebugLogLocation.append("[\(f.string(from: Date()))] \(message)\n", to: Self.debugLogName)
    }
    #endif

    init(serverURL: String, username: String, password: String) throws {
        self.baseURL = try Self.parseBaseURL(serverURL)
        self.username = username
        self.password = password

        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        config.timeoutIntervalForRequest = 30

        let delegate = OWASessionDelegate(username: username, password: password)
        self.sessionDelegate = delegate
        self.session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        #if DEBUG
        setupDebugLog()
        #endif
    }

    /// Single chokepoint for network requests. Converts a TLS trust rejection
    /// (recorded by the session delegate) into a typed `untrustedCertificate` error so
    /// the UI / background sync can prompt the user to trust the server.
    private func fetchData(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            if let pending = sessionDelegate.takePendingUntrusted() {
                throw OWAError.untrustedCertificate(
                    host: pending.host,
                    port: pending.port,
                    fingerprint: pending.fingerprint
                )
            }
            // The NTLM/Negotiate handshake declined our credentials. This arrives as a generic
            // `NSURLErrorCancelled` (-999); the delegate flag is what distinguishes a real
            // credential rejection from an ordinary task cancellation. Map it to the definitive
            // auth error so the wrong-password breaker latches immediately.
            if sessionDelegate.takeAuthRejected() {
                throw OWAError.authenticationFailed(
                    "Integrated auth (NTLM/Negotiate) rejected credentials for \(username)."
                )
            }
            throw error
        }
    }

    // MARK: - Auth

    /// Removes all cookies from this session's in-memory store. The `URLSession` is dedicated
    /// to a single OWA host, so clearing all of them is equivalent to clearing the host's.
    private func clearSessionCookies() {
        guard let storage = session.configuration.httpCookieStorage else { return }
        let cookies = storage.cookies ?? []
        for cookie in cookies {
            storage.deleteCookie(cookie)
        }
        if !cookies.isEmpty {
            log.debug("Cleared \(cookies.count, privacy: .public) stale session cookie(s) before reauth")
        }
    }

    func authenticate() async throws {
        let syncID = SyncDiagnostics.syncIDText
        log.info("OWA auth started sync=\(syncID, privacy: .public)")
        sessionDelegate.reset()
        // Drop any cookies left over from a previous (now-expired) session before logging in
        // afresh. The login flow re-sets everything it needs; this just prevents a stale cookie
        // from a prior session riding alongside the new ones if the server doesn't overwrite it.
        clearSessionCookies()

        // Path A — Integrated Windows Auth (NTLM). Since OWA moved to SSO the server returns
        // `401 WWW-Authenticate: Negotiate, NTLM` for every request; the session delegate answers
        // the NTLM leg, so a plain authenticated GET /owa/ returns the page + CANARY with no forms
        // login at all. A rejected handshake throws `authenticationFailed` from `fetchData` (via
        // the delegate's auth-rejected flag); a connectivity failure (VPN off) throws its URLError
        // — both propagate out as-is. Only a *successful* GET that simply lacks a CANARY falls
        // through to the forms-login fallback below.
        try await fetchCanaryFromOWAPage()
        collectCanaryFromSession(html: nil)
        if canaryToken != nil {
            log.info("OWA auth OK via integrated auth sync=\(syncID, privacy: .public)")
            return
        }
        log.debug("No CANARY via integrated auth — falling back to forms login")

        // Path B — legacy OWA forms-based login (servers still on forms auth).
        // 1. Скачиваем страницу логина, получаем action и скрытые поля формы
        let loginForm = try await fetchLoginForm()
        log.debug("Login form action: \(loginForm.action), fields: \(loginForm.hiddenFields.map(\.0))")

        // 2. POST — отправляем ровно то, что в форме + логин/пароль
        let (authData, authResponse) = try await submitAuthForm(form: loginForm)
        let authFinalURL = authResponse.url?.absoluteString ?? "nil"
        log.debug("Auth final URL: \(authFinalURL), status: \(authResponse.statusCode)")
        log.debug("Redirects: \(self.sessionDelegate.redirectChain)")

        // 3. Extract CANARY from cookies (redirect chain + session storage) and the auth HTML.
        let delegateCookies = sessionDelegate.allCookies
        log.debug("Delegate cookies: \(delegateCookies.map(\.name))")
        collectCanaryFromSession(html: authData)

        // 4. GET /owa/ as authenticated user — CANARY should be in the page HTML
        if canaryToken == nil {
            try await fetchCanaryFromOWAPage()
        }

        guard canaryToken != nil else {
            let bodyPreview = String(data: authData.prefix(500), encoding: .utf8)?
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: "")
                .trimmingCharacters(in: .whitespaces)
                .prefix(300)
            let detail =
                "No CANARY. " +
                "FormAction: \(loginForm.action). " +
                "AuthURL: \(authFinalURL) (HTTP \(authResponse.statusCode)). " +
                "Redirects: \(sessionDelegate.redirectChain.joined(separator: "|")). " +
                "Cookies: \(delegateCookies.map(\.name)). " +
                "AuthBody[\(authData.count)]: \(bodyPreview ?? "?")"

            // We never reach this guard on success (a CANARY would be set), so "no CANARY" means
            // one of three things, classified on the response *content* rather than a bare status
            // code (so captive 200 pages stay out of the latch and bad-password re-renders are
            // caught even with a non-2xx status):
            //   (a) We reached an OWA forms-logon surface that declined to grant a session — a
            //       confirmed credential rejection → `authenticationFailed`, which latches the
            //       wrong-password breaker immediately.
            //   (b) An explicit 401/440 without an OWA logon page in hand — a genuine rejection or
            //       a transient session/LB blip. Surface as `httpError`: still an auth error
            //       (`isAuthError`), so it rides out the breaker threshold, but NOT a definitive
            //       logon-page rejection — this avoids latching "wrong password" on a single 440
            //       session-timeout.
            //   (c) We never reached a working OWA login at all: an external reverse proxy
            //       answering `/owa/auth.owa` with a 404 while VPN is off, a 5xx, or a captive-
            //       portal / SSO interstitial returning its own 200 HTML. Connectivity, not
            //       credentials → a connectivity error that `isAuthError` ignores and the breaker
            //       treats as a transient/offline condition that self-heals once the network path
            //       is restored.
            let reachedLogon = Self.responseLooksLikeOWALogon(finalURL: authResponse.url, body: authData)
            if reachedLogon {
                throw OWAError.authenticationFailed(detail)
            }
            if authResponse.statusCode == 401 || authResponse.statusCode == 440 {
                throw OWAError.httpError(authResponse.statusCode, detail)
            }
            // Throw a connectivity error rather than `httpError(statusCode, detail)`. A
            // hand-built `URLError` has no localized description (its `localizedDescription` falls
            // back to the cryptic "operation couldn't be completed … error -1004"), so attach a
            // clean localized message: that is what surfaces in the offline status footer and the
            // connection test, while the verbose diagnostic stays in the log line below instead of
            // leaking into the UI. `isAuthError` ignores `URLError`, so the breaker treats this as
            // a transient/offline condition that self-heals once the network path is restored.
            log.warning(
                "OWA auth got no CANARY without reaching an OWA logon page (status \(authResponse.statusCode, privacy: .public)) — treating as connectivity, not bad credentials. \(detail, privacy: .public)"
            )
            throw URLError(
                .cannotConnectToHost,
                userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("error.owa.unreachable", comment: "Shown when OWA could not be reached, e.g. the VPN is off")]
            )
        }
        log.info("OWA auth OK sync=\(syncID, privacy: .public)")
    }

    // MARK: - Login form

    private struct LoginForm {
        var action: String          // абсолютный URL для POST
        var hiddenFields: [(String, String)]  // name → value из <input type="hidden">
        var referer: String         // URL страницы логина
    }

    /// Скачивает страницу /owa/, следует редиректу на logon.aspx,
    /// парсит форму и возвращает все нужные для POST данные.
    private func fetchLoginForm() async throws -> LoginForm {
        var req = URLRequest(url: try url("/owa/"))
        addCommonHeaders(&req)

        let fallback = LoginForm(
            action: try url("/owa/auth.owa").absoluteString,
            hiddenFields: [
                ("destination",    try url("/owa/?bFS=1").absoluteString),
                ("flags",          "4"),
                ("forcedownlevel", "0"),
                ("isUtf8",         "1"),
            ],
            referer: try url("/owa/auth/logon.aspx").absoluteString
        )

        // Propagate an untrusted-certificate rejection here instead of swallowing it into
        // the fallback form — otherwise the typed error (and the delegate's pending record,
        // which is cleared on read) would be lost and the trust prompt might never surface.
        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await self.fetchData(req)
        } catch let error as OWAError {
            if case .untrustedCertificate = error { throw error }
            if case .authenticationFailed = error { throw error }
            return fallback
        } catch let urlError as URLError {
            // Connectivity failure reaching the login page (host unreachable, DNS, timeout —
            // e.g. the OWA host is only routable over VPN, which is currently off). Do NOT fold
            // this into the fallback login form: that would march the flow into a bogus
            // "No CANARY" `authenticationFailed`, which the sync breaker latches as a false
            // "wrong password". Propagate it so the breaker classifies it as offline instead.
            throw urlError
        } catch {
            return fallback
        }
        guard let http = resp as? HTTPURLResponse,
              let pageURL = http.url,
              let html = String(data: data, encoding: .utf8) else {
            return fallback
        }

        let referer = pageURL.absoluteString

        // Извлекаем action из <form … action="…">
        var actionURL = try url("/owa/auth.owa").absoluteString
        if let re = try? NSRegularExpression(pattern: #"<form[^>]+action="([^"]+)""#, options: .caseInsensitive) {
            let ns = html as NSString
            if let m = re.firstMatch(in: html, range: NSRange(location: 0, length: ns.length)),
               m.numberOfRanges > 1 {
                let raw = ns.substring(with: m.range(at: 1))
                // Может быть относительным URL
                if raw.hasPrefix("http") {
                    // Принимаем абсолютный action только если он на том же хосте, что и
                    // страница с формой (pageURL). Это пропускает легитимную федерацию
                    // (ADFS/login.microsoftonline.com — форма и POST на одном чужом хосте),
                    // но блокирует подмену action на сторонний хост (эксфильтрация пароля).
                    if let extracted = URL(string: raw),
                       extracted.host?.lowercased() == pageURL.host?.lowercased() {
                        actionURL = raw
                    }
                    // иначе оставляем безопасный дефолт actionURL (/owa/auth.owa)
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

        log.debug("Parsed form: action=\(actionURL), fields=\(hiddenFields.map(\.0))")
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

        let (data, response) = try await self.fetchData(request)
        guard let http = response as? HTTPURLResponse else { throw OWAError.invalidResponse }
        return (data, http)
    }

    private func fetchCanaryFromOWAPage() async throws {
        var req = URLRequest(url: try url("/owa/"))
        addCommonHeaders(&req)
        let (data, _) = try await self.fetchData(req)
        if let html = String(data: data, encoding: .utf8) {
            canaryToken = extractCanaryFromHTML(html)
        }
    }

    /// Pulls the CANARY token from wherever the server may have placed it: cookies captured
    /// during redirects, the session's own cookie storage, or (optionally) an HTML body. A no-op
    /// once `canaryToken` is already set.
    private func collectCanaryFromSession(html: Data?) {
        if canaryToken == nil {
            canaryToken = sessionDelegate.allCookies.first(where: { $0.name == "X-OWA-CANARY" })?.value
        }
        if canaryToken == nil {
            let stored = session.configuration.httpCookieStorage?.cookies ?? []
            canaryToken = stored.first(where: { $0.name == "X-OWA-CANARY" })?.value
        }
        if canaryToken == nil, let html, let text = String(data: html, encoding: .utf8) {
            canaryToken = extractCanaryFromHTML(text)
        }
    }

    // MARK: - Calendar view

    func fetchCalendarView(from start: Date, to end: Date) async throws -> [OWACalendarItem] {
        let syncID = SyncDiagnostics.syncIDText
        let hasCanary = canaryToken != nil
        let isForceDistinguished = forceDistinguishedCalendarFolder
        log.info(
            "Calendar view fetch started sync=\(syncID, privacy: .public) hasCanary=\(hasCanary, privacy: .public) forceDistinguished=\(isForceDistinguished, privacy: .public)"
        )
        var afterFreshAuth = false
        if canaryToken == nil {
            try await authenticate()
            afterFreshAuth = true
        }
        do {
            let items = try await performCalendarViewRequestWithStartupRetry(
                from: start,
                to: end,
                afterFreshAuth: afterFreshAuth
            )
            log.info("Calendar view fetch complete sync=\(syncID, privacy: .public) items=\(items.count, privacy: .public)")
            return items
        } catch let error as OWAError where OWAError.isSessionStaleHTTPError(error) {
            // 401/440 (expired session) or 449 ("Retry With" on a stale cookie): the server is
            // reachable but rejects this session. See `isSessionStaleHTTPError`. Force a full
            // reauth — `authenticate()` clears the stale cookies and re-runs the NTLM handshake —
            // then retry once on the clean session instead of surfacing a bogus "offline" status.
            log.warning("Calendar view session stale (\(error.localizedDescription, privacy: .private)) sync=\(syncID, privacy: .public); reauthenticating")
            canaryToken = nil
            try await authenticate()
            let items = try await performCalendarViewRequestWithStartupRetry(
                from: start,
                to: end,
                afterFreshAuth: true
            )
            log.info("Calendar view fetch complete after reauth sync=\(syncID, privacy: .public) items=\(items.count, privacy: .public)")
            return items
        } catch {
            // Startup retries only run when this invocation authenticated first. If we reused an
            // existing CANARY from a prior sync, a transient Exchange 500 "abstract class" fault
            // used to surface immediately — one forced reauth restores the retry path.
            if OWAError.isAbstractClassHTTPError(error), hasCanary {
                log.warning(
                    "Calendar view abstract-class fault with existing session sync=\(syncID, privacy: .public); reauthenticating once"
                )
                canaryToken = nil
                try await authenticate()
                let items = try await performCalendarViewRequestWithStartupRetry(
                    from: start,
                    to: end,
                    afterFreshAuth: true
                )
                log.info(
                    "Calendar view fetch complete after abstract-class reauth sync=\(syncID, privacy: .public) items=\(items.count, privacy: .public)"
                )
                return items
            }
            log.error("Calendar view fetch failed sync=\(syncID, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    private func performCalendarViewRequestWithStartupRetry(
        from start: Date,
        to end: Date,
        afterFreshAuth: Bool
    ) async throws -> [OWACalendarItem] {
        var attempt = 0

        while true {
            do {
                return try await performCalendarViewRequest(from: start, to: end)
            } catch {
                guard let delay = OWAStartupRetryPolicy.delayBeforeRetry(
                    attempt: attempt,
                    error: error,
                    afterFreshAuth: afterFreshAuth
                ) else {
                    throw error
                }

                attempt += 1
                log.warning(
                    "Retrying startup OWA abstract-class fault sync=\(SyncDiagnostics.syncIDText, privacy: .public) nextAttempt=\(attempt + 1, privacy: .public)"
                )
                try await Task.sleep(for: delay)
            }
        }
    }

    private func performCalendarViewRequest(from start: Date, to end: Date) async throws -> [OWACalendarItem] {
        guard let canary = canaryToken else { throw OWAError.notAuthenticated }

        let folderIdentifier = forceDistinguishedCalendarFolder
            ? nil
            : try await resolveDefaultCalendarFolderIdentifier(canary: canary)
        let folderMode = folderIdentifier == nil ? "distinguished" : "folderId"
        let isForceDistinguished = forceDistinguishedCalendarFolder
        log.info(
            "Calendar view request mode sync=\(SyncDiagnostics.syncIDText, privacy: .public) folderMode=\(folderMode, privacy: .public) forceDistinguished=\(isForceDistinguished, privacy: .public)"
        )

        do {
            return try await executeCalendarViewRequest(
                from: start,
                to: end,
                canary: canary,
                folderIdentifier: folderIdentifier
            )
        } catch OWAError.httpError(let statusCode, let message) {
            if statusCode == 500,
               message.localizedCaseInsensitiveContains("cannot create an abstract class"),
               folderIdentifier != nil,
               !forceDistinguishedCalendarFolder {
                log.warning("OWA rejected FolderId with abstract class error sync=\(SyncDiagnostics.syncIDText, privacy: .public); switching to DistinguishedFolderId fallback")
                forceDistinguishedCalendarFolder = true
                defaultCalendarFolderIdentifier = nil
                return try await executeCalendarViewRequest(
                    from: start,
                    to: end,
                    canary: canary,
                    folderIdentifier: nil
                )
            }
            throw OWAError.httpError(statusCode, message)
        }
    }

    private func executeCalendarViewRequest(
        from start: Date,
        to end: Date,
        canary: String,
        folderIdentifier: OWAFolderIdentifier?
    ) async throws -> [OWACalendarItem] {
        let requestDict = OWACalendarViewRequestPayload.make(
            start: start,
            end: end,
            timezoneID: windowsTimezoneID(),
            folderIdentifier: folderIdentifier
        )

        let jsonData = try JSONSerialization.data(withJSONObject: requestDict)
        guard let jsonString = String(data: jsonData, encoding: .utf8) else { throw OWAError.encodingFailed }

        requestSequence += 1
        let requestID = requestSequence
        let started = Date()
        let syncID = SyncDiagnostics.syncIDText
        let folderMode = folderIdentifier == nil ? "distinguished" : "folderId"

        var request = try serviceRequest(action: "GetCalendarView", canary: canary)
        request.setValue(jsonString.formEncoded, forHTTPHeaderField: "X-OWA-UrlPostData")

        let (data, response) = try await self.fetchData(request)
        guard let http = response as? HTTPURLResponse else { throw OWAError.invalidResponse }
        let durationMS = Int(Date().timeIntervalSince(started) * 1000)
        log.info(
            "OWA request completed sync=\(syncID, privacy: .public) request=\(requestID, privacy: .public) action=GetCalendarView folderMode=\(folderMode, privacy: .public) status=\(http.statusCode, privacy: .public) bytes=\(data.count, privacy: .public) durationMs=\(durationMS, privacy: .public)"
        )
        #if DEBUG
        dumpGetCalendarViewResponseIfNeeded(
            data: data,
            statusCode: http.statusCode,
            requestID: requestID,
            syncID: syncID
        )
        #endif

        guard (200..<300).contains(http.statusCode) else {
            let msg = String(data: data.prefix(300), encoding: .utf8) ?? ""
            log.warning(
                "OWA request failed sync=\(syncID, privacy: .public) request=\(requestID, privacy: .public) action=GetCalendarView folderMode=\(folderMode, privacy: .public) status=\(http.statusCode, privacy: .public) responseKind=\(OWAError.diagnosticResponseKind(from: msg), privacy: .public)"
            )
            throw OWAError.httpError(http.statusCode, msg)
        }

        return (try JSONDecoder().decode(OWAServiceResponse.self, from: data)).Body?.Items ?? []
    }

    // MARK: - GetCalendarEvent (attendees + full body)

    /// Lazily fetches attendees and the full body for a single meeting. `GetCalendarView` omits
    /// attendee collections and truncates the body to a 255-character `Preview`, so the detail
    /// panel calls this on demand. Replicates the OWA web client's `GetCalendarEvent` peek request
    /// (HAR-captured), including the `X-OWA-ActionId` headers; both pieces come from one response.
    func fetchMeetingDetails(itemId: String, changeKey: String?, attempt: Int = 0) async throws -> CalendarEventDetails {
        let canary = try await ensureCanary()
        try Task.checkCancellation()

        let payload = OWAGetCalendarEventPayload.make(
            itemId: itemId,
            changeKey: changeKey,
            timezoneID: windowsTimezoneID()
        )
        let jsonString = Self.serializeJSONTypeFirst(payload)
        let jsonBody = Data(jsonString.utf8)

        guard var components = URLComponents(url: try url("/owa/service.svc"), resolvingAgainstBaseURL: false) else {
            throw OWAError.invalidURL("/owa/service.svc")
        }
        components.queryItems = [
            URLQueryItem(name: "action", value: "GetCalendarEvent"),
            URLQueryItem(name: "EP", value: "1"),
            URLQueryItem(name: "ID", value: "-1725"),
            URLQueryItem(name: "AC", value: "1"),
        ]
        guard let serviceURL = components.url else { throw OWAError.invalidURL("/owa/service.svc") }

        var request = URLRequest(url: serviceURL, timeoutInterval: 18)
        request.httpMethod = "POST"
        request.httpBody = jsonBody
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("ru,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue(canary, forHTTPHeaderField: "X-OWA-CANARY")
        request.setValue("GetCalendarEvent", forHTTPHeaderField: "Action")
        request.setValue("-1725", forHTTPHeaderField: "X-OWA-ActionId")
        request.setValue("GetCalendarEventAction", forHTTPHeaderField: "X-OWA-ActionName")
        request.setValue("1", forHTTPHeaderField: "X-OWA-Attempt")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue(baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")), forHTTPHeaderField: "Origin")
        let correlationId = Self.makeCorrelationId()
        request.setValue(correlationId, forHTTPHeaderField: "X-OWA-CorrelationId")
        request.setValue(correlationId, forHTTPHeaderField: "client-request-id")
        request.setValue(Self.iso8601Millis(Date()), forHTTPHeaderField: "X-OWA-ClientBegin")
        request.setValue("15.2.1748.10", forHTTPHeaderField: "X-OWA-ClientBuildVersion")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )

        let started = Date()
        let syncID = SyncDiagnostics.syncIDText
        let (data, response) = try await sessionDataAllowingStaleReconnect(for: request)
        guard let http = response as? HTTPURLResponse else { throw OWAError.invalidResponse }
        let durationMS = Int(Date().timeIntervalSince(started) * 1000)
        log.info(
            "OWA request completed sync=\(syncID, privacy: .public) action=GetCalendarEvent status=\(http.statusCode, privacy: .public) bytes=\(data.count, privacy: .public) durationMs=\(durationMS, privacy: .public)"
        )

        #if DEBUG
        DebugLogLocation.write(data, to: "getcalendarevent_last.json")
        #endif

        if OWAError.isSessionStaleStatus(http.statusCode) {
            canaryToken = nil
            guard attempt < 1 else {
                throw OWAError.httpError(http.statusCode, "GetCalendarEvent auth retry exhausted")
            }
            try await authenticate()
            return try await fetchMeetingDetails(itemId: itemId, changeKey: changeKey, attempt: attempt + 1)
        }

        guard (200..<300).contains(http.statusCode) else {
            let msg = String(data: data.prefix(300), encoding: .utf8) ?? ""
            log.warning(
                "OWA request failed sync=\(syncID, privacy: .public) action=GetCalendarEvent status=\(http.statusCode, privacy: .public) responseKind=\(OWAError.diagnosticResponseKind(from: msg), privacy: .public)"
            )
            throw OWAError.httpError(http.statusCode, msg)
        }

        let body = OWACalendarEventBodyParser.body(fromJSONData: data)
        return CalendarEventDetails(
            attendees: OWACalendarEventAttendeesParser.attendees(fromJSONData: data),
            body: body?.text,
            bodyHTML: body?.html
        )
    }

    /// Dumps the raw `GetCalendarView` response — every meeting title, attendee and agenda the
    /// mailbox returns — for debugging sync problems.
    ///
    /// DEBUG-only. It used to compile into release builds behind nothing but a hidden
    /// `debugDumpGetCalendarViewResponse` default, writing the rawest data in the app to
    /// `owa-debug/` as world-readable 0644 files in a 0755 directory: the one place on disk with
    /// weaker permissions than everything around it. Now it cannot be switched on in a shipped
    /// build at all, and what it writes in DEBUG is encrypted like every other trace.
    #if DEBUG
    private func dumpGetCalendarViewResponseIfNeeded(
        data: Data,
        statusCode: Int,
        requestID: Int,
        syncID: String
    ) {
        guard isGetCalendarViewDebugEnabled() else { return }

        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let name = "getcalendarview-\(timestamp)-status\(statusCode)-req\(requestID)-sync\(syncID).json"
        let outputData = prettyPrintedJSONDataIfPossible(from: data) ?? data
        DebugLogLocation.write(outputData, to: name)
        log.notice(
            "OWA GetCalendarView debug dump saved sync=\(syncID, privacy: .public) request=\(requestID, privacy: .public) status=\(statusCode, privacy: .public)"
        )
    }
    #endif

    #if DEBUG
    private func prettyPrintedJSONDataIfPossible(from data: Data) -> Data? {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }

    private func isGetCalendarViewDebugEnabled() -> Bool {
        let env = ProcessInfo.processInfo.environment
        if let raw = env["OWA_DEBUG_GETCALENDARVIEW_RESPONSE"]?.lowercased() {
            return raw == "1" || raw == "true" || raw == "yes"
        }
        return UserDefaults.standard.bool(forKey: getCalendarViewDebugFlagKey)
    }
    #endif

    func respondToMeeting(itemId: String, changeKey: String, action: MeetingResponseAction) async throws {
        try await performEWSRespondRequest(itemId: itemId, changeKey: changeKey, action: action)
    }

    /// Retries a few times on stale HTTP keep-alive (`URLError.networkConnectionLost`).
    private func sessionDataAllowingStaleReconnect(for request: URLRequest) async throws -> (Data, URLResponse) {
        let maxStaleRetries = 3
        var attempt = 0
        while true {
            attempt += 1
            do {
                return try await self.fetchData(request)
            } catch let urlError as URLError where urlError.code == .networkConnectionLost {
                #if DEBUG
                dlog("sessionData: networkConnectionLost attempt \(attempt)/\(maxStaleRetries)")
                #endif
                guard attempt < maxStaleRetries else {
                    #if DEBUG
                    dlog("sessionData: giving up after \(maxStaleRetries) stale-connection failures")
                    #endif
                    throw urlError
                }
                try await Task.sleep(nanoseconds: 80_000_000)
            }
        }
    }

    // MARK: - FindPeople (OWA JSON ComposeHAR)

    #if DEBUG
    private static let findPeopleTraceName = "findpeople_trace.log"

    private nonisolated func ftrace(_ message: String) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        DebugLogLocation.append("[\(f.string(from: Date()))] \(message)\n", to: Self.findPeopleTraceName)
    }
    #endif

    func findPeople(query: String) async throws -> [ResolvedAttendee] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return [] }

        try Task.checkCancellation()
        let direct = try await findPeopleComposeHAR(query: trimmed)
        if !direct.isEmpty { return direct }

        let tokens = trimmed.split(whereSeparator: { $0.isWhitespace })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 2 }
        guard tokens.count >= 2 else { return [] }

        let sortedTokens = tokens.sorted { $0.count > $1.count }
        for seed in sortedTokens {
            try Task.checkCancellation()
            let broad = try await findPeopleComposeHAR(query: seed)
            guard !broad.isEmpty else { continue }
            let seedLower = seed.lowercased()
            let otherTokens = tokens.map { $0.lowercased() }.filter { $0 != seedLower }
            guard !otherTokens.isEmpty else { continue }
            let narrowed = broad.filter { person in
                otherTokens.allSatisfy { token in
                    person.displayName.lowercased().contains(token) ||
                    person.email.lowercased().contains(token)
                }
            }
            if !narrowed.isEmpty { return narrowed }
        }

        return []
    }

    private func findPeopleComposeHAR(query: String, attempt: Int = 0) async throws -> [ResolvedAttendee] {
        let canary = try await ensureCanary()
        try Task.checkCancellation()

        let payload = OWAFindPeoplePayload.makeComposeCalendarHAR(
            query: query,
            timezoneID: windowsTimezoneID()
        )
        let jsonString = Self.serializeJSONTypeFirst(payload)
        let jsonBody = Data(jsonString.utf8)

        guard var components = URLComponents(url: try url("/owa/service.svc"), resolvingAgainstBaseURL: false) else {
            throw OWAError.invalidURL("/owa/service.svc")
        }
        components.queryItems = [
            URLQueryItem(name: "action", value: "FindPeople"),
            URLQueryItem(name: "ID", value: "-199"),
            URLQueryItem(name: "AC", value: "1"),
        ]
        guard let serviceURL = components.url else { throw OWAError.invalidURL("/owa/service.svc") }

        var request = URLRequest(url: serviceURL, timeoutInterval: 18)
        request.httpMethod = "POST"
        request.httpBody = jsonBody
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("ru,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue(canary, forHTTPHeaderField: "X-OWA-CANARY")
        request.setValue("FindPeople", forHTTPHeaderField: "Action")
        request.setValue("-199", forHTTPHeaderField: "X-OWA-ActionId")
        request.setValue("ComposeForms", forHTTPHeaderField: "X-OWA-ActionName")
        request.setValue("1", forHTTPHeaderField: "X-OWA-Attempt")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue(baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")), forHTTPHeaderField: "Origin")
        let correlationId = Self.makeCorrelationId()
        request.setValue(correlationId, forHTTPHeaderField: "X-OWA-CorrelationId")
        request.setValue(correlationId, forHTTPHeaderField: "client-request-id")
        request.setValue(Self.iso8601Millis(Date()), forHTTPHeaderField: "X-OWA-ClientBegin")
        request.setValue("15.2.1748.10", forHTTPHeaderField: "X-OWA-ClientBuildVersion")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("?0", forHTTPHeaderField: "sec-ch-ua-mobile")
        request.setValue("\"macOS\"", forHTTPHeaderField: "sec-ch-ua-platform")

        #if DEBUG
        ftrace("=== FindPeople REQUEST ===")
        ftrace("URL: \(serviceURL.absoluteString)")
        ftrace("Method: POST")
        if let headers = request.allHTTPHeaderFields {
            for k in headers.keys.sorted() {
                let v = headers[k] ?? ""
                let display = (k.uppercased() == "X-OWA-CANARY" || k.lowercased() == "authorization") ? "<redacted len=\(v.count)>" : v
                ftrace("Header: \(k): \(display)")
            }
        }
        let cookieJar = session.configuration.httpCookieStorage
        if let cookies = cookieJar?.cookies(for: serviceURL) {
            let names = cookies.map(\.name).sorted().joined(separator: ", ")
            ftrace("Cookies sent (\(cookies.count)): \(names)")
        }
        ftrace("Body bytes: \(jsonBody.count)")
        ftrace("Body:\n\(jsonString)")
        #endif

        let (data, response) = try await sessionDataAllowingStaleReconnect(for: request)
        guard let http = response as? HTTPURLResponse else { throw OWAError.invalidResponse }

        #if DEBUG
        ftrace("=== FindPeople RESPONSE ===")
        ftrace("Status: \(http.statusCode)")
        for (k, v) in http.allHeaderFields {
            ftrace("RespHeader: \(k): \(v)")
        }
        let raw = String(data: data, encoding: .utf8) ?? "<non-utf8 bytes=\(data.count)>"
        ftrace("Body bytes: \(data.count)")
        ftrace("Body:\n\(raw)")
        ftrace("=== END ===\n")
        #endif

        if OWAError.isSessionStaleStatus(http.statusCode) {
            canaryToken = nil
            guard attempt < 1 else {
                throw OWAError.httpError(http.statusCode, "FindPeople auth retry exhausted")
            }
            try await authenticate()
            return try await findPeopleComposeHAR(query: query, attempt: attempt + 1)
        }

        guard (200..<300).contains(http.statusCode) else { return [] }
        return OWAFindPeopleParser.attendees(fromJSONData: data)
    }

    /// Serialize JSON with `__type` always FIRST. .NET DataContractJsonSerializer needs the discriminator
    /// before any other property when the destination is an abstract base — otherwise it throws
    /// `MemberAccessException: "Cannot create an abstract class."` mid-parse.
    private static func serializeJSONTypeFirst(_ obj: Any) -> String {
        if let dict = obj as? [String: Any] {
            var keys = Array(dict.keys)
            keys.sort { a, b in
                if a == "__type" && b != "__type" { return true }
                if b == "__type" && a != "__type" { return false }
                return a < b
            }
            let parts = keys.map { key -> String in
                let value = dict[key] ?? NSNull()
                return "\(escapeJSONString(key)):\(serializeJSONTypeFirst(value))"
            }
            return "{" + parts.joined(separator: ",") + "}"
        }
        if let arr = obj as? [Any] {
            return "[" + arr.map { serializeJSONTypeFirst($0) }.joined(separator: ",") + "]"
        }
        if let b = obj as? Bool {
            return b ? "true" : "false"
        }
        if let n = obj as? NSNumber {
            // NSNumber may be wrapped Bool — handled above. Otherwise numeric.
            return n.stringValue
        }
        if let i = obj as? Int { return String(i) }
        if let d = obj as? Double { return String(d) }
        if let s = obj as? String {
            return escapeJSONString(s)
        }
        if obj is NSNull { return "null" }
        return "null"
    }

    private static func escapeJSONString(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
        return out
    }

    private static func makeCorrelationId() -> String {
        let hex = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let suffix = String(Int64.random(in: 100_000_000_000_000...999_999_999_999_999))
        return "\(hex)_\(suffix)"
    }

    private static func iso8601Millis(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        return f.string(from: date)
    }

    // MARK: - Organizer SMTP resolution

    func resolveOrganizerSMTPEmail() async throws -> String? {
        if let cached = cachedOrganizerSMTPEmail { return cached }
        // Strip domain prefix: "DOMAIN\username" → "username"
        let alias = username.components(separatedBy: "\\").last ?? username
        let results = (try? await findPeople(query: alias)) ?? []
        // Prefer exact alias match in email localpart, fall back to first result
        let match = results.first(where: { $0.email.lowercased().hasPrefix(alias.lowercased()) }) ?? results.first
        cachedOrganizerSMTPEmail = match?.email
        #if DEBUG
        dlog("resolveOrganizerSMTPEmail: alias='\(alias)' → \(match?.email ?? "nil")")
        #endif
        return match?.email
    }

    // MARK: - GetUserAvailabilityInternal

    func getUserAvailabilityInternal(emails: [String], from start: Date, to end: Date) async throws -> [AttendeeAvailability] {
        try await getUserAvailabilityInternal(emails: emails, from: start, to: end, attempt: 0)
    }

    private func getUserAvailabilityInternal(emails: [String], from start: Date, to end: Date, attempt: Int) async throws -> [AttendeeAvailability] {
        let canary = try await ensureCanary()
        let payload = OWAUserAvailabilityPayload.make(emails: emails, start: start, end: end, timezoneID: windowsTimezoneID())
        let jsonData = try JSONSerialization.data(withJSONObject: payload)
        let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"

        var req = try serviceRequest(action: "GetUserAvailabilityInternal", canary: canary)
        req.setValue(jsonString.formEncoded, forHTTPHeaderField: "X-OWA-UrlPostData")

        let (data, response) = try await self.fetchData(req)
        if let http = response as? HTTPURLResponse, OWAError.isSessionStaleStatus(http.statusCode) {
            canaryToken = nil
            guard attempt < 1 else {
                throw OWAError.httpError(http.statusCode, "GetUserAvailabilityInternal auth retry exhausted")
            }
            try await authenticate()
            return try await getUserAvailabilityInternal(emails: emails, from: start, to: end, attempt: attempt + 1)
        }
        #if DEBUG
        dlog("getUserAvailability: windowStart=\(start) emails=\(emails)")
        if let raw = String(data: data, encoding: .utf8) {
            dlog("getUserAvailability: raw response (first 1000):\n\(String(raw.prefix(1000)))")
        }
        #endif
        return parseAvailabilityResponse(data, emails: emails, windowStart: start)
    }

    private func parseAvailabilityResponse(_ data: Data, emails: [String], windowStart: Date) -> [AttendeeAvailability] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var mergedStrings: [String] = []
        collectMergedFreeBusy(from: json, into: &mergedStrings)

        #if DEBUG
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        for (email, merged) in zip(emails, mergedStrings) {
            // Decode: index i → windowStart + i*30min, char: 0=free 1=tentative 2=busy 3=OOF
            let slots = merged.enumerated().map { (i, ch) -> String in
                let t = windowStart.addingTimeInterval(Double(i) * 1800)
                return "\(fmt.string(from: t))=\(ch)"
            }
            dlog("availability[\(email)]: \(merged)")
            dlog("  decoded slots: \(slots.joined(separator: " "))")
        }
        #endif

        return zip(emails, mergedStrings).map { email, merged in
            AttendeeAvailability(
                email: email,
                mergedFreeBusy: merged,
                windowStart: windowStart,
                intervalMinutes: 30
            )
        }
    }

    private func collectMergedFreeBusy(from value: Any, into results: inout [String]) {
        if let dict = value as? [String: Any] {
            if let merged = dict["MergedFreeBusy"] as? String, !merged.isEmpty {
                results.append(merged)
                return
            }
            for val in dict.values {
                collectMergedFreeBusy(from: val, into: &results)
            }
        } else if let arr = value as? [Any] {
            for item in arr {
                collectMergedFreeBusy(from: item, into: &results)
            }
        }
    }

    // MARK: - CreateCalendarEvent (EWS SOAP)

    func createCalendarEvent(
        title: String,
        agenda: String,
        location: String = "",
        start: Date,
        end: Date,
        requiredAttendees: [ResolvedAttendee],
        optionalAttendees: [ResolvedAttendee] = [],
        folderIdentifier: OWAFolderIdentifier?
    ) async throws {
        try await createCalendarEvent(
            title: title,
            agenda: agenda,
            location: location,
            start: start,
            end: end,
            requiredAttendees: requiredAttendees,
            optionalAttendees: optionalAttendees,
            folderIdentifier: folderIdentifier,
            attempt: 0
        )
    }

    private func createCalendarEvent(
        title: String,
        agenda: String,
        location: String,
        start: Date,
        end: Date,
        requiredAttendees: [ResolvedAttendee],
        optionalAttendees: [ResolvedAttendee],
        folderIdentifier: OWAFolderIdentifier?,
        attempt: Int
    ) async throws {
        let soap = OWACreateCalendarEventPayload.createItemSOAP(
            title: title,
            agenda: agenda,
            location: location,
            start: start,
            end: end,
            requiredAttendees: requiredAttendees,
            optionalAttendees: optionalAttendees
        )

        let ewsURL = try url("/EWS/Exchange.asmx")
        var request = URLRequest(url: ewsURL, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        // Auth is handled by the session delegate's NTLM/Negotiate handshake (same path as the
        // OWA service calls); no manual Basic header — the SSO server ignores it anyway.
        request.setValue(
            "\"http://schemas.microsoft.com/exchange/services/2006/messages/CreateItem\"",
            forHTTPHeaderField: "SOAPAction"
        )
        addCommonHeaders(&request)
        request.httpBody = Data(soap.utf8)

        log.info("EWS CreateItem → \(ewsURL.absoluteString, privacy: .public) subject=\(title, privacy: .private) required=\(requiredAttendees.count, privacy: .public) optional=\(optionalAttendees.count, privacy: .public) bodyBytes=\(soap.utf8.count, privacy: .public)")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await sessionDataAllowingStaleReconnect(for: request)
        } catch let urlErr as URLError {
            log.error("EWS CreateItem URLError code=\(urlErr.code.rawValue, privacy: .public) (\(urlErr.localizedDescription, privacy: .public))")
            throw urlErr
        } catch {
            log.error("EWS CreateItem network error: \(error, privacy: .public)")
            throw error
        }

        guard let http = response as? HTTPURLResponse else { throw OWAError.invalidResponse }

        if OWAError.isSessionStaleStatus(http.statusCode) {
            guard attempt < 1 else {
                // Стойкая ошибка сессии после одной переаутентификации. Бросаем httpError с
                // РЕАЛЬНЫМ статусом: 401/440 → isAuthError → CalendarService переводит аккаунт в
                // .authenticationRequired (пароль протух, защита от lockout AD); 449 ("Retry With")
                // НЕ является isAuthError — всплывёт как транзиентная ошибка, аккаунт не латчим.
                log.error("EWS CreateItem HTTP \(http.statusCode, privacy: .public) — auth retry exhausted, surfacing error")
                throw OWAError.httpError(http.statusCode, "EWS CreateItem auth retry exhausted")
            }
            log.info("EWS CreateItem HTTP \(http.statusCode, privacy: .public) — re-authenticating")
            try await authenticate()
            try await createCalendarEvent(
                title: title,
                agenda: agenda,
                location: location,
                start: start,
                end: end,
                requiredAttendees: requiredAttendees,
                optionalAttendees: optionalAttendees,
                folderIdentifier: folderIdentifier,
                attempt: attempt + 1
            )
            return
        }

        let body = String(data: data, encoding: .utf8) ?? ""
        if (200..<300).contains(http.statusCode) {
            log.info("EWS CreateItem HTTP \(http.statusCode, privacy: .public)")
        } else {
            log.error("EWS CreateItem HTTP \(http.statusCode, privacy: .public) body=\(body.prefix(1000), privacy: .private)")
        }
        #if DEBUG
        dlog("createCalendarEvent: HTTP \(http.statusCode) response:\n\(body.prefix(800))")
        #endif

        guard (200..<300).contains(http.statusCode) else {
            throw OWAError.httpError(http.statusCode, body)
        }
        let code = extractEWSResponseCode(from: body)
        log.info("EWS CreateItem responseCode=\(code ?? "nil", privacy: .public)")
        guard code == "NoError" else {
            throw OWAError.ewsError(code ?? "UnknownError")
        }
    }

    // MARK: - Public accessors

    var resolvedFolderIdentifier: OWAFolderIdentifier? {
        defaultCalendarFolderIdentifier
    }

    // MARK: - Auth helper

    private func ensureCanary() async throws -> String {
        if let token = canaryToken { return token }
        try await authenticate()
        guard let token = canaryToken else { throw OWAError.notAuthenticated }
        return token
    }

    private func performEWSRespondRequest(itemId: String, changeKey: String, action: MeetingResponseAction) async throws {
        let elementName: String
        switch action {
        case .accept:    elementName = "AcceptItem"
        case .tentative: elementName = "TentativelyAcceptItem"
        case .decline:   elementName = "DeclineItem"
        }

        let soap = """
        <?xml version="1.0" encoding="utf-8"?>
        <soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/" \
        xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types" \
        xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages">
          <soap:Header>
            <t:RequestServerVersion Version="Exchange2013_SP1"/>
          </soap:Header>
          <soap:Body>
            <m:CreateItem MessageDisposition="SendAndSaveCopy">
              <m:Items>
                <t:\(elementName)>
                  <t:ReferenceItemId Id="\(itemId)" ChangeKey="\(changeKey)"/>
                </t:\(elementName)>
              </m:Items>
            </m:CreateItem>
          </soap:Body>
        </soap:Envelope>
        """

        let ewsURL = try url("/EWS/Exchange.asmx")
        var request = URLRequest(url: ewsURL, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        // Auth handled by the session delegate's NTLM/Negotiate handshake — no manual Basic header.
        request.setValue(
            "\"http://schemas.microsoft.com/exchange/services/2006/messages/CreateItem\"",
            forHTTPHeaderField: "SOAPAction"
        )
        addCommonHeaders(&request)
        request.httpBody = Data(soap.utf8)

        log.info(
            "EWS respondToMeeting itemId=\(String(itemId.prefix(40)), privacy: .public) action=\(elementName, privacy: .public)"
        )

        let (data, response) = try await sessionDataAllowingStaleReconnect(for: request)
        guard let http = response as? HTTPURLResponse else { throw OWAError.invalidResponse }
        let responseBody = String(data: data.prefix(600), encoding: .utf8) ?? ""
        log.info(
            "EWS respondToMeeting status=\(http.statusCode, privacy: .public) bytes=\(data.count, privacy: .public)"
        )
        log.debug("EWS respondToMeeting response preview=\(responseBody, privacy: .private)")

        guard (200..<300).contains(http.statusCode) else {
            throw OWAError.httpError(http.statusCode, responseBody)
        }

        // EWS returns HTTP 200 even for errors — check SOAP body
        if let soapError = extractEWSResponseCode(from: responseBody), soapError != "NoError" {
            throw OWAError.httpError(200, soapError)
        }
    }

    private func extractEWSResponseCode(from body: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: "<m:ResponseCode>([^<]+)</m:ResponseCode>") else { return nil }
        let ns = body as NSString
        guard let match = re.firstMatch(in: body, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges > 1 else { return nil }
        return ns.substring(with: match.range(at: 1))
    }

    private func resolveDefaultCalendarFolderIdentifier(canary: String) async throws -> OWAFolderIdentifier? {
        if let defaultCalendarFolderIdentifier {
            return defaultCalendarFolderIdentifier
        }

        var request = try serviceRequest(action: "GetCalendarFolders", canary: canary)
        request.setValue("{}".formEncoded, forHTTPHeaderField: "X-OWA-UrlPostData")

        let (data, response) = try await self.fetchData(request)
        guard let http = response as? HTTPURLResponse else { throw OWAError.invalidResponse }
        log.info(
            "OWA GetCalendarFolders completed sync=\(SyncDiagnostics.syncIDText, privacy: .public) status=\(http.statusCode, privacy: .public) bytes=\(data.count, privacy: .public)"
        )
        guard (200..<300).contains(http.statusCode) else {
            let msg = String(data: data.prefix(300), encoding: .utf8) ?? ""
            log.warning(
                "GetCalendarFolders failed sync=\(SyncDiagnostics.syncIDText, privacy: .public) status=\(http.statusCode, privacy: .public) responseKind=\(OWAError.diagnosticResponseKind(from: msg), privacy: .public)"
            )
            return nil
        }

        let folderIdentifier = OWACalendarFoldersParser.defaultCalendarFolderIdentifier(from: data)
        defaultCalendarFolderIdentifier = folderIdentifier
        if folderIdentifier == nil {
            log.warning("GetCalendarFolders returned no calendar FolderId sync=\(SyncDiagnostics.syncIDText, privacy: .public); falling back to distinguished calendar folder")
        } else {
            log.info("GetCalendarFolders selected FolderId sync=\(SyncDiagnostics.syncIDText, privacy: .public)")
        }
        return folderIdentifier
    }

    // MARK: - Helpers

    private func url(_ path: String) throws -> URL {
        guard let url = URL(string: baseURL.absoluteString + path) else {
            throw OWAError.invalidURL(path)
        }
        return url
    }

    private func serviceURL(action: String) throws -> URL {
        guard var components = URLComponents(url: try url("/owa/service.svc"), resolvingAgainstBaseURL: false) else {
            throw OWAError.invalidURL("/owa/service.svc")
        }
        components.queryItems = [
            URLQueryItem(name: "action", value: action),
            URLQueryItem(name: "EP", value: "1"),
        ]
        guard let serviceURL = components.url else {
            throw OWAError.invalidURL("/owa/service.svc")
        }
        return serviceURL
    }

    private func serviceRequest(action: String, canary: String) throws -> URLRequest {
        var request = URLRequest(url: try serviceURL(action: action))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(canary, forHTTPHeaderField: "X-OWA-CANARY")
        request.setValue(action, forHTTPHeaderField: "Action")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.httpBody = Data()
        addCommonHeaders(&request)
        return request
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
        let scheme = (parsed.scheme ?? "https").lowercased()
        // Credentials must never travel over cleartext HTTP.
        guard scheme == "https" else {
            throw OWAError.invalidURL(input)
        }
        let port   = parsed.port.map { ":\($0)" } ?? ""
        guard let base = URL(string: "\(scheme)://\(host)\(port)") else {
            throw OWAError.invalidURL(input)
        }
        return base
    }

    /// Heuristic used when an authentication attempt produced no CANARY: did the flow actually
    /// land on an OWA forms-logon surface (so a missing CANARY means the credentials were
    /// rejected), or did it never reach OWA at all (an external reverse-proxy 404 while VPN is
    /// off, a 5xx, or a captive-portal / SSO page answering with its own HTML)?
    ///
    /// Returns `true` only when the final URL or the response body carries an OWA-specific
    /// marker. A generic captive-portal/proxy page has none of these, so it is correctly treated
    /// as connectivity rather than a wrong password. Conversely, a bad-password response that
    /// re-renders `logon.aspx` is recognised even if it arrives with a non-2xx status.
    static func responseLooksLikeOWALogon(finalURL: URL?, body: Data) -> Bool {
        // Only `logon.aspx` in the FINAL url is a reliable signal: OWA redirects a declined
        // forms login to logon.aspx. `auth.owa` is deliberately NOT matched here — it is the POST
        // target, so a proxy answering that path with a 404 (VPN off) leaves the final url on
        // auth.owa without ever rendering an OWA logon page.
        if let path = finalURL?.path.lowercased(), path.contains("logon.aspx") {
            return true
        }
        // Decode the (capped) body as ISO Latin-1, NOT UTF-8: Latin-1 maps every byte 0–255 to a
        // code point, so it never returns nil. That keeps the scan robust to the page's charset
        // (RU Exchange often serves logon.aspx as windows-1251) and to the `prefix` cut landing
        // mid multi-byte sequence — every marker below is pure ASCII and survives byte-for-byte in
        // any ASCII superset. The cap bounds work; logon markers appear near the top.
        guard let html = String(bytes: body.prefix(64_000), encoding: .isoLatin1)?.lowercased() else {
            return false
        }
        // OWA's forms-logon page is rendered by the `auth_logon` ASP page (`OwaPage =
        // ASP.auth_logon_aspx`) and/or references `logon.aspx`. These are OWA-specific. The POST
        // target `/owa/auth.owa` is deliberately NOT a body marker: a proxy/SSO error page can
        // echo the requested path verbatim, which would falsely read as an OWA logon page.
        if html.contains("logon.aspx") || html.contains("auth_logon") {
            return true
        }
        // Fallback: OWA's logon form emits a `passwd` field alongside its signature hidden
        // fields. Require the combination — a lone password input is too generic (captive
        // portals have those too) to attribute to OWA.
        let hasOWAPasswordField = html.contains("name=\"passwd\"")
        let hasOWAHiddenField = html.contains("name=\"destination\"")
            || html.contains("name=\"flags\"")
            || html.contains("name=\"isutf8\"")
        return hasOWAPasswordField && hasOWAHiddenField
    }
}

private extension String {
    var formEncoded: String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }
}
