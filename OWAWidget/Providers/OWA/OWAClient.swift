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
    private var defaultCalendarFolderIdentifier: OWAFolderIdentifier?
    private var forceDistinguishedCalendarFolder = false
    private var requestSequence = 0
    private var cachedOrganizerSMTPEmail: String?
    /// Default GAL address list id from `GetPeopleFilters`, required for `FindPeople` on many Exchange builds.
    private var cachedGalAddressListFolderId: String?
    private var galFolderIdFetchCompleted = false
    /// After a successful `FindPeople`, retry that payload shape first (fewer round-trips per keystroke).
    private var preferredFindPeoplePayloadVariant: FindPeoplePayloadVariant?
    private let sessionDelegate: OWASessionDelegate
    private let session: URLSession
    private let log = Logger(subsystem: "com.owawidget", category: "OWAClient")
    private let getCalendarViewDebugFlagKey = "debugDumpGetCalendarViewResponse"

    #if DEBUG
    private static let debugLogURL = URL(fileURLWithPath: "/tmp/owawidget_owaclient.log")

    private nonisolated func setupDebugLog() {
        let header = "=== OWAClient Log started \(Date()) ===\n"
        try? header.write(to: Self.debugLogURL, atomically: true, encoding: .utf8)
    }

    private nonisolated func dlog(_ message: String) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        let line = "[\(f.string(from: Date()))] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: Self.debugLogURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: Self.debugLogURL, options: .atomic)
        }
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

        let delegate = OWASessionDelegate()
        self.sessionDelegate = delegate
        self.session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        #if DEBUG
        setupDebugLog()
        #endif
    }

    // MARK: - Auth

    func authenticate() async throws {
        let syncID = SyncDiagnostics.syncIDText
        log.info("OWA auth started sync=\(syncID, privacy: .public)")
        sessionDelegate.reset()
        cachedGalAddressListFolderId = nil
        galFolderIdFetchCompleted = false
        preferredFindPeoplePayloadVariant = nil

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
        } catch OWAError.httpError(440, _), OWAError.httpError(401, _) {
            log.warning("Calendar view auth expired sync=\(syncID, privacy: .public); reauthenticating")
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

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OWAError.invalidResponse }
        let durationMS = Int(Date().timeIntervalSince(started) * 1000)
        log.info(
            "OWA request completed sync=\(syncID, privacy: .public) request=\(requestID, privacy: .public) action=GetCalendarView folderMode=\(folderMode, privacy: .public) status=\(http.statusCode, privacy: .public) bytes=\(data.count, privacy: .public) durationMs=\(durationMS, privacy: .public)"
        )
        dumpGetCalendarViewResponseIfNeeded(
            data: data,
            statusCode: http.statusCode,
            requestID: requestID,
            syncID: syncID
        )

        guard (200..<300).contains(http.statusCode) else {
            let msg = String(data: data.prefix(300), encoding: .utf8) ?? ""
            log.warning(
                "OWA request failed sync=\(syncID, privacy: .public) request=\(requestID, privacy: .public) action=GetCalendarView folderMode=\(folderMode, privacy: .public) status=\(http.statusCode, privacy: .public) responseKind=\(OWAError.diagnosticResponseKind(from: msg), privacy: .public)"
            )
            throw OWAError.httpError(http.statusCode, msg)
        }

        return (try JSONDecoder().decode(OWAServiceResponse.self, from: data)).Body?.Items ?? []
    }

    private func dumpGetCalendarViewResponseIfNeeded(
        data: Data,
        statusCode: Int,
        requestID: Int,
        syncID: String
    ) {
        guard isGetCalendarViewDebugEnabled() else { return }

        let fileManager = FileManager.default
        let appSupportBase = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        let debugDirectory = appSupportBase
            .appendingPathComponent("OWAWidget", isDirectory: true)
            .appendingPathComponent("owa-debug", isDirectory: true)
        do {
            try fileManager.createDirectory(at: debugDirectory, withIntermediateDirectories: true)
            let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let filename = "getcalendarview-\(timestamp)-status\(statusCode)-req\(requestID)-sync\(syncID).json"
            let fileURL = debugDirectory.appendingPathComponent(filename)
            let outputData = prettyPrintedJSONDataIfPossible(from: data) ?? data
            try outputData.write(to: fileURL, options: .atomic)
            log.notice(
                "OWA GetCalendarView debug dump saved sync=\(syncID, privacy: .public) request=\(requestID, privacy: .public) status=\(statusCode, privacy: .public) path=\(fileURL.path, privacy: .public)"
            )
        } catch {
            log.error(
                "OWA GetCalendarView debug dump failed sync=\(syncID, privacy: .public) request=\(requestID, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }

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
                return try await session.data(for: request)
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
    private static let findPeopleTraceURL = URL(fileURLWithPath: "/tmp/owawidget_findpeople_trace.log")

    private nonisolated func ftrace(_ message: String) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        let line = "[\(f.string(from: Date()))] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: Self.findPeopleTraceURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: Self.findPeopleTraceURL, options: .atomic)
        }
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

    private func findPeopleComposeHAR(query: String) async throws -> [ResolvedAttendee] {
        let canary = try await ensureCanary()
        try Task.checkCancellation()

        let payload = OWAFindPeoplePayload.makeComposeCalendarHAR(
            query: query,
            timezoneID: windowsTimezoneID()
        )
        let jsonString = Self.serializeJSONTypeFirst(payload)
        let jsonBody = Data(jsonString.utf8)

        var components = URLComponents(url: url("/owa/service.svc"), resolvingAgainstBaseURL: false)!
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

        if http.statusCode == 440 || http.statusCode == 401 {
            canaryToken = nil
            try await authenticate()
            return try await findPeopleComposeHAR(query: query)
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
                let value = dict[key]!
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
        // Strip domain prefix: "moscow\U_M1G4U" → "U_M1G4U"
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
        let canary = try await ensureCanary()
        let payload = OWAUserAvailabilityPayload.make(emails: emails, start: start, end: end, timezoneID: windowsTimezoneID())
        let jsonData = try JSONSerialization.data(withJSONObject: payload)
        let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"

        var req = try serviceRequest(action: "GetUserAvailabilityInternal", canary: canary)
        req.setValue(jsonString.formEncoded, forHTTPHeaderField: "X-OWA-UrlPostData")

        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode == 440 || http.statusCode == 401 {
            canaryToken = nil
            try await authenticate()
            return try await getUserAvailabilityInternal(emails: emails, from: start, to: end)
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
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"

        func attendeesXML(_ list: [ResolvedAttendee]) -> String {
            list.map { a in
                "<t:Attendee><t:Mailbox><t:EmailAddress>\(escapeXML(a.email))</t:EmailAddress></t:Mailbox></t:Attendee>"
            }.joined()
        }

        let requiredXML = attendeesXML(requiredAttendees)
        // EWS schema order: RequiredAttendees must precede OptionalAttendees in CalendarItem.
        let optionalXML = optionalAttendees.isEmpty
            ? ""
            : "<t:OptionalAttendees>\(attendeesXML(optionalAttendees))</t:OptionalAttendees>"

        let agendaTrimmed = agenda.trimmingCharacters(in: .whitespacesAndNewlines)
        let bodyXML: String
        if agendaTrimmed.isEmpty {
            bodyXML = ""
        } else {
            let html = OWACreateCalendarEventPayload.calendarBodyHTML(plainAgenda: agenda)
            bodyXML = "<t:Body BodyType=\"HTML\"><![CDATA[\(html)]]></t:Body>"
        }

        let soap = """
        <?xml version="1.0" encoding="utf-8"?>
        <soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/" \
        xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types" \
        xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages">
          <soap:Header>
            <t:RequestServerVersion Version="Exchange2013_SP1"/>
            <t:TimeZoneContext><t:TimeZoneDefinition Id="UTC"/></t:TimeZoneContext>
          </soap:Header>
          <soap:Body>
            <m:CreateItem SendMeetingInvitations="SendToAllAndSaveCopy">
              <m:SavedItemFolderId><t:DistinguishedFolderId Id="calendar"/></m:SavedItemFolderId>
              <m:Items>
                <t:CalendarItem>
                  <t:Subject>\(escapeXML(title))</t:Subject>
                  \(bodyXML)
                  \(location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : "<t:Location>\(escapeXML(location.trimmingCharacters(in: .whitespacesAndNewlines)))</t:Location>")
                  <t:Start>\(fmt.string(from: start))</t:Start>
                  <t:End>\(fmt.string(from: end))</t:End>
                  <t:IsReminderSet>true</t:IsReminderSet>
                  <t:ReminderMinutesBeforeStart>15</t:ReminderMinutesBeforeStart>
                  <t:RequiredAttendees>\(requiredXML)</t:RequiredAttendees>
                  \(optionalXML)
                </t:CalendarItem>
              </m:Items>
            </m:CreateItem>
          </soap:Body>
        </soap:Envelope>
        """

        let ewsURL = url("/EWS/Exchange.asmx")
        var request = URLRequest(url: ewsURL, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        let credentials = "\(username):\(password)"
        request.setValue("Basic \(Data(credentials.utf8).base64EncodedString())", forHTTPHeaderField: "Authorization")
        request.setValue(
            "\"http://schemas.microsoft.com/exchange/services/2006/messages/CreateItem\"",
            forHTTPHeaderField: "SOAPAction"
        )
        addCommonHeaders(&request)
        request.httpBody = Data(soap.utf8)

        log.info("EWS CreateItem subject=\(title, privacy: .private) required=\(requiredAttendees.count, privacy: .public) optional=\(optionalAttendees.count, privacy: .public)")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OWAError.invalidResponse }

        if http.statusCode == 401 {
            try await authenticate()
            try await createCalendarEvent(
                title: title,
                agenda: agenda,
                location: location,
                start: start,
                end: end,
                requiredAttendees: requiredAttendees,
                optionalAttendees: optionalAttendees,
                folderIdentifier: folderIdentifier
            )
            return
        }

        let body = String(data: data, encoding: .utf8) ?? ""
        #if DEBUG
        dlog("createCalendarEvent: HTTP \(http.statusCode) response:\n\(body.prefix(800))")
        #endif

        guard (200..<300).contains(http.statusCode) else {
            throw OWAError.httpError(http.statusCode, body)
        }
        let code = extractEWSResponseCode(from: body)
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

        let ewsURL = url("/EWS/Exchange.asmx")
        var request = URLRequest(url: ewsURL, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        let credentials = "\(username):\(password)"
        let basicAuth = "Basic \(Data(credentials.utf8).base64EncodedString())"
        request.setValue(basicAuth, forHTTPHeaderField: "Authorization")
        request.setValue(
            "\"http://schemas.microsoft.com/exchange/services/2006/messages/CreateItem\"",
            forHTTPHeaderField: "SOAPAction"
        )
        addCommonHeaders(&request)
        request.httpBody = Data(soap.utf8)

        log.info(
            "EWS respondToMeeting itemId=\(String(itemId.prefix(40)), privacy: .public) action=\(elementName, privacy: .public)"
        )

        let (data, response) = try await session.data(for: request)
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

    private func escapeXML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
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

        let (data, response) = try await session.data(for: request)
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

    private func url(_ path: String) -> URL {
        URL(string: baseURL.absoluteString + path)!
    }

    private func serviceURL(action: String) throws -> URL {
        var components = URLComponents(url: url("/owa/service.svc"), resolvingAgainstBaseURL: false)!
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
