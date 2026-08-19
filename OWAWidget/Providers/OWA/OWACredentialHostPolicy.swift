import Foundation

/// Decides which host is allowed to receive the account's credentials.
///
/// Redirects are followed across hosts on purpose — federated / ADFS login depends on it — and the
/// `URLSession` delegate is asked to answer authentication challenges for whatever host the request
/// ends up on. Without a rule of its own that means any host in the redirect chain can ask for the
/// domain account: it answers `401 WWW-Authenticate: NTLM`, `URLSession` runs the handshake itself,
/// and the NTLMv2 response — offline-crackable, relayable — leaves the machine. Stripping the
/// `Authorization` header across a host change does not help, because that header is not how NTLM
/// travels.
///
/// The rule is exact-match, not suffix-match. A suffix rule would hand credentials to
/// `mail.example.com.attacker.test` from the first mistyped label, and the sibling-host case it
/// would buy (`autodiscover.example.com`) is not one this client makes requests to.
///
/// Split out of the session delegate so the decision is testable without a live TLS session.
enum OWACredentialHostPolicy {

    /// Authentication methods that hand the account's own credentials to the peer.
    ///
    /// Server trust is deliberately absent: it is TLS evaluation rather than a credential, it has
    /// to run for every host the request reaches, and the pin store is keyed by host anyway.
    static func carriesCredentials(_ authenticationMethod: String) -> Bool {
        switch authenticationMethod {
        case NSURLAuthenticationMethodNTLM,
             NSURLAuthenticationMethodNegotiate,
             NSURLAuthenticationMethodHTTPBasic,
             NSURLAuthenticationMethodHTTPDigest,
             NSURLAuthenticationMethodHTMLForm:
            return true
        default:
            return false
        }
    }

    /// Whether `challengeHost` may be given the credentials configured for `configuredHost`.
    ///
    /// An empty configured host refuses everything. That is the state a client built from a URL
    /// with no host would be in, and "we do not know whose credentials these are" has to fail
    /// closed — the alternative is an empty string matching an empty `protectionSpace.host`.
    static func allowsCredentials(challengeHost: String, configuredHost: String) -> Bool {
        let configured = normalizedHost(configuredHost)
        guard !configured.isEmpty else { return false }
        return normalizedHost(challengeHost) == configured
    }

    /// Case- and trailing-dot-insensitive. `mail.example.com.` and `mail.example.com` are the same
    /// name in DNS, and a redirect that adds the root label must not read as a different host.
    ///
    /// Not private: ``TrustedLoginHostStore`` keys its approvals with this, and a second copy of
    /// the rule would let the guard and the approval drift apart without failing a test.
    static func normalizedHost(_ host: String) -> String {
        var value = host.trimmingCharacters(in: .whitespaces).lowercased()
        while value.hasSuffix(".") { value.removeLast() }
        return value
    }
}
