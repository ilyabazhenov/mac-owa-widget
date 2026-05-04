import Foundation

/// Startup-only retry for OWA's post-auth calendar-view instability.
///
/// This is intentionally narrower than a generic retry loop. Logs showed two
/// different cases:
/// - immediately after fresh auth, `GetCalendarView` can fail once or several
///   times with HTTP 500 `Cannot create an abstract class`, then start working;
/// - during rapid manual refresh, repeated retries amplify likely throttling.
///
/// Therefore this policy is used only after `authenticate()`/reauth. Normal
/// manual refresh failures are handled by `SyncRequestGate` cooldown instead.
enum OWAStartupRetryPolicy {
    private static let retryDelays: [Duration] = [
        .milliseconds(700),
        .milliseconds(1_500),
        .seconds(3),
        .seconds(6),
        .seconds(10),
        .seconds(20),
    ]

    static func delayBeforeRetry(
        attempt: Int,
        error: Error,
        afterFreshAuth: Bool
    ) -> Duration? {
        guard afterFreshAuth,
              OWAError.isAbstractClassHTTPError(error),
              retryDelays.indices.contains(attempt)
        else { return nil }

        return retryDelays[attempt]
    }
}
