import Foundation

/// A login flow that was steered at a host other than the account's configured server.
///
/// Federated sign-in (ADFS, and anything else that answers `/owa/` with a redirect to an identity
/// provider) is a legitimate reason for this to happen, and it is why the redirect is followed at
/// all. It is also exactly what credential theft looks like: whoever controls the server's
/// responses picks the host the password gets typed into. The two are indistinguishable from
/// inside the client, so the client does not try — it stops and asks, once per host, the same way
/// it asks about a self-signed certificate.
struct UnapprovedLoginHost: Equatable, Sendable {
    /// Host of the server the account is configured against.
    var configuredHost: String
    /// Host the login form actually wants the credentials posted to.
    var loginHost: String
    /// The redirects that led there, newest last, for the prompt to show. Best effort: an empty
    /// chain means the hop was not observed as an HTTP redirect.
    var redirectChain: [String]
}
