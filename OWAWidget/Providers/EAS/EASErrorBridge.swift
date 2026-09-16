import Foundation

/// Translates EAS failures into the `OWAError` vocabulary `CalendarService` reasons about.
///
/// This is not cosmetic renaming. `CalendarService` decides the sync status, whether to show
/// the certificate-trust prompt, and whether to latch the authentication circuit breaker by
/// branching on `OWAError` statics — `isAuthError`, `isDefinitiveAuthRejection`,
/// `untrustedCertificateInfo(from:)`. An error that does not map lands in the generic
/// "offline / unknown failure" bucket, and the breaker never engages.
///
/// The name stays `OWAError` on purpose: it is the language the service speaks, carries no
/// network behaviour of its own, and renaming it would mean editing a working OWA path.
enum EASErrorBridge {

    static func owaError(from error: Error, context: String) -> Error {
        // Already translated, or thrown by shared code that speaks OWAError.
        if error is OWAError { return error }

        guard let eas = error as? EASError else {
            // URLError and friends pass through untouched: `CalendarService` reads them as a
            // transient connectivity failure and falls back to the cached calendar, which is
            // exactly right when the network is down rather than the password wrong.
            return error
        }

        switch eas {
        case .authenticationRejected:
            // Maps to the *definitive* rejection, which latches the breaker on the first
            // failure instead of riding the threshold. Correct for Basic authentication —
            // a 401 here is an answer, not a challenge — and strictly safer for lockout.
            return OWAError.authenticationFailed("EAS 401 during \(context)")

        case .forbidden(let detail):
            // The password is fine; access is. Must not latch the wrong-password breaker.
            return OWAError.httpError(403, detail)

        case .http(let code, let detail):
            return OWAError.httpError(code, detail)

        case .protocolError:
            return OWAError.invalidResponse

        case .commandStatus(let command, let status):
            // Both halves matter, and an earlier version kept only the first: the code is what
            // a bug report can be looked up by, the sentence is what makes the popover mean
            // something to whoever is reading it. `EASError.explain` returns static English —
            // no mailbox data — so it is safe to surface.
            let explanation = EASError.explain(status)
            let detail = explanation.isEmpty
                ? "\(command) Status=\(status)"
                : "\(command) Status=\(status) — \(explanation)"
            return OWAError.ewsError(detail)

        case .calendarFolderNotFound:
            return OWAError.ewsError("EASNoCalendarFolder")

        case .deviceIdentityUnreadable:
            return OWAError.ewsError("EASDeviceIdentityUnreadable")
        }
    }
}
