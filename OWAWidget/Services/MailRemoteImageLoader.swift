import Darwin
import Foundation

/// Fetches a message's remote images after the user asked to load them.
///
/// The URLs come from the sender, so the loader treats them as hostile: only `https` to hosts on
/// the public internet (names that resolve into private, loopback or link-local ranges are
/// refused, as are single-label and `.local`-style names), redirects held to the same rule, no
/// cookies, no cache and no credentials of any kind (a corporate Mac would otherwise answer an
/// NTLM or Kerberos challenge from an intranet host), and a byte cap enforced while downloading.
enum MailRemoteImageLoader {
    static let maxImages = 30
    static let maxBytes = 2 * 1024 * 1024

    static func load(_ sources: [String]) async -> [String: (data: Data, type: String)] {
        let delegate = Delegate()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 20
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        var images: [String: (data: Data, type: String)] = [:]
        // One line per host and reason: a newsletter repeats the same host dozens of times.
        var refusals: [String: Int] = [:]
        let candidates = Array(sources.prefix(maxImages))
        for source in candidates {
            guard let url = URL(string: source) else {
                refusals["host=? reason=malformed URL", default: 0] += 1
                continue
            }
            let host = url.host?.lowercased() ?? "?"
            if let reason = await refusal(for: url) {
                refusals["host=\(host) reason=\(reason)", default: 0] += 1
                continue
            }
            switch await fetch(url, session: session) {
            case .success(let image): images[source] = image
            case .failure(let failure): refusals["host=\(host) reason=\(failure.reason)", default: 0] += 1
            }
        }
        for (line, count) in refusals.sorted(by: { $0.key < $1.key }) {
            DiagnosticLog.event("Mail remote image refused \(line)" + (count > 1 ? " ×\(count)" : ""))
        }
        DiagnosticLog.event("Mail remote images loaded \(images.count) of \(candidates.count)")
        return images
    }

    /// Why a fetch gave no image, for the diagnostic log.
    struct FetchFailure: Error {
        let reason: String
    }

    private static func fetch(_ url: URL, session: URLSession) async -> Result<(data: Data, type: String), FetchFailure> {
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            let code = (error as? URLError)?.code
            // A refused credential challenge surfaces as a cancelled request.
            let reason = code == .cancelled ? "authentication required (credentials are never sent)" : "network error \(code.map { String($0.rawValue) } ?? "?")"
            return .failure(FetchFailure(reason: reason))
        }
        guard let http = response as? HTTPURLResponse else { return .failure(FetchFailure(reason: "not an HTTP response")) }
        guard (200..<300).contains(http.statusCode) else {
            let redirect = (300..<400).contains(http.statusCode) ? " (redirect refused)" : ""
            return .failure(FetchFailure(reason: "HTTP \(http.statusCode)\(redirect)"))
        }
        guard let type = http.mimeType, type.hasPrefix("image/") else {
            return .failure(FetchFailure(reason: "not an image (\(http.mimeType ?? "no type"))"))
        }
        if http.expectedContentLength > Int64(maxBytes) { return .failure(FetchFailure(reason: "larger than \(maxBytes) bytes")) }
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count > maxBytes { return .failure(FetchFailure(reason: "larger than \(maxBytes) bytes")) }
            }
        } catch {
            return .failure(FetchFailure(reason: "download interrupted"))
        }
        return .success((data, type))
    }

    // MARK: - Where a sender's URL may point

    /// `https`, a public-looking name, and every address it resolves to public.
    static func isAllowed(_ url: URL) async -> Bool {
        await refusal(for: url) == nil
    }

    /// Why the loader will not fetch this URL; `nil` when it may.
    static func refusal(for url: URL) async -> String? {
        let scheme = url.scheme?.lowercased() ?? ""
        guard scheme == "https" else { return "not https (\(scheme.isEmpty ? "no scheme" : scheme))" }
        guard let host = url.host?.lowercased() else { return "no host" }
        guard isPublicName(host) else { return "private or local name" }
        let addresses = await Task.detached { resolve(host) }.value
        guard !addresses.isEmpty else { return "does not resolve" }
        if let address = addresses.first(where: { !isPublicAddress($0) }) {
            return "resolves to a private address (\(address))"
        }
        return nil
    }

    /// Single-label names and the suffixes networks keep for themselves never leave the LAN.
    static func isPublicName(_ host: String) -> Bool {
        let name = host.hasSuffix(".") ? String(host.dropLast()) : host
        guard !name.isEmpty else { return false }
        if let literal = IPAddress(name) { return isPublicAddress(literal) }
        guard name.contains(".") else { return false }
        let local = [".local", ".localhost", ".internal", ".intranet", ".lan", ".home.arpa", ".localdomain"]
        return name != "localhost" && !local.contains { name.hasSuffix($0) }
    }

    static func isPublicAddress(_ address: IPAddress) -> Bool {
        switch address {
        case .v4(let a, let b, _, _):
            switch (a, b) {
            case (0, _), (10, _), (127, _), (169, 254), (192, 168), (255, _): return false
            case (172, 16...31): return false
            case (100, 64...127): return false  // carrier-grade NAT
            case (224...239, _): return false  // multicast
            default: return true
            }
        case .v6(let bytes):
            if bytes.allSatisfy({ $0 == 0 }) || bytes == [UInt8](repeating: 0, count: 15) + [1] { return false }  // :: and ::1
            if bytes[0] & 0xFE == 0xFC { return false }  // fc00::/7 unique local
            if bytes[0] == 0xFE, bytes[1] & 0xC0 == 0x80 { return false }  // fe80::/10 link-local
            if bytes[0] == 0xFF { return false }  // multicast
            if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF {  // IPv4-mapped
                return isPublicAddress(.v4(bytes[12], bytes[13], bytes[14], bytes[15]))
            }
            return true
        }
    }

    enum IPAddress: Equatable, CustomStringConvertible {
        case v4(UInt8, UInt8, UInt8, UInt8)
        case v6([UInt8])

        var description: String {
            switch self {
            case .v4(let a, let b, let c, let d): return "\(a).\(b).\(c).\(d)"
            case .v6(let bytes):
                return stride(from: 0, to: bytes.count, by: 2).map { String(format: "%x", Int(bytes[$0]) << 8 | Int(bytes[$0 + 1])) }.joined(separator: ":")
            }
        }

        init?(_ text: String) {
            let trimmed = text.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            var v4 = in_addr()
            if inet_pton(AF_INET, trimmed, &v4) == 1 {
                let value = UInt32(bigEndian: v4.s_addr)
                self = .v4(UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF))
                return
            }
            var v6 = in6_addr()
            if inet_pton(AF_INET6, trimmed, &v6) == 1 {
                self = .v6(withUnsafeBytes(of: &v6) { Array($0) })
                return
            }
            return nil
        }
    }

    /// Every address the name resolves to; empty when it does not resolve.
    private static func resolve(_ host: String) -> [IPAddress] {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, "443", &hints, &result) == 0, let first = result else { return [] }
        defer { freeaddrinfo(first) }
        var addresses: [IPAddress] = []
        var node: UnsafeMutablePointer<addrinfo>? = first
        while let current = node {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(current.pointee.ai_addr, current.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0,
               let address = IPAddress(String(cString: buffer).split(separator: "%").first.map(String.init) ?? "") {
                addresses.append(address)
            }
            node = current.pointee.ai_next
        }
        return addresses
    }

    // MARK: - Session delegate

    private final class Delegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        /// Server trust is checked as usual; any request for credentials is refused.
        func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
                completionHandler(.performDefaultHandling, nil)
            } else {
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        }

        /// A redirect is held to the same rule as the first URL (name only: no blocking lookup
        /// on the delegate queue).
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            guard let url = request.url, url.scheme?.lowercased() == "https", let host = url.host?.lowercased(),
                  MailRemoteImageLoader.isPublicName(host) else {
                completionHandler(nil)
                return
            }
            completionHandler(request)
        }
    }
}
