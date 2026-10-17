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
        for source in sources.prefix(maxImages) {
            guard let url = URL(string: source), await isAllowed(url) else { continue }
            if let image = await fetch(url, session: session) { images[source] = image }
        }
        return images
    }

    private static func fetch(_ url: URL, session: URLSession) async -> (data: Data, type: String)? {
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        guard let (bytes, response) = try? await session.bytes(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let type = http.mimeType, type.hasPrefix("image/") else { return nil }
        if http.expectedContentLength > Int64(maxBytes) { return nil }
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count > maxBytes { return nil }
            }
        } catch {
            return nil
        }
        return (data, type)
    }

    // MARK: - Where a sender's URL may point

    /// `https`, a public-looking name, and every address it resolves to public.
    static func isAllowed(_ url: URL) async -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(), isPublicName(host) else { return false }
        let addresses = await Task.detached { resolve(host) }.value
        return !addresses.isEmpty && addresses.allSatisfy(isPublicAddress)
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

    enum IPAddress: Equatable {
        case v4(UInt8, UInt8, UInt8, UInt8)
        case v6([UInt8])

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
