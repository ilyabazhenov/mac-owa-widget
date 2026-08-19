import Foundation

enum SyncStatus: Sendable {
    case idle
    case syncing
    case lastSynced(Date)
    case offlineCached(String)
    case error(String)
    /// Sync is suspended because the stored credentials were rejected by the server.
    /// Resumes when the user updates the password, taps the "retry" action, or a slow
    /// background auto-probe succeeds (e.g. after a transient failure or a cleared lockout).
    case authenticationRequired
    /// Sync is suspended because the server presented an untrusted certificate
    /// (e.g. a self-signed cert rotated). Resumes after the user re-trusts the server.
    case certificateTrustRequired(host: String, fingerprint: String)
    /// Sync is suspended because the login flow was redirected at a host the user has not approved
    /// for this server. Resumes once the user approves that host (or fixes the server URL).
    case loginHostApprovalRequired(configuredHost: String, loginHost: String)

    var displayText: String {
        switch self {
        case .idle:
            return "Not synced yet"
        case .syncing:
            return "Syncing..."
        case .lastSynced(let date):
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated
            return "Synced \(formatter.localizedString(for: date, relativeTo: Date()))"
        case .offlineCached(let msg):
            return "Offline: \(msg)"
        case .error(let msg):
            return "Error: \(msg)"
        case .authenticationRequired:
            return NSLocalizedString("sync.status.auth.required", comment: "")
        case .certificateTrustRequired:
            return NSLocalizedString("sync.status.certificate.untrusted", comment: "")
        case .loginHostApprovalRequired:
            return NSLocalizedString("sync.status.login.host.approval", comment: "")
        }
    }

    var isSyncing: Bool {
        if case .syncing = self { return true }
        return false
    }

    var isError: Bool {
        if case .error = self { return true }
        return false
    }

    var isOfflineCached: Bool {
        if case .offlineCached = self { return true }
        return false
    }

    var isAuthenticationRequired: Bool {
        if case .authenticationRequired = self { return true }
        return false
    }

    var isCertificateTrustRequired: Bool {
        if case .certificateTrustRequired = self { return true }
        return false
    }

    var isLoginHostApprovalRequired: Bool {
        if case .loginHostApprovalRequired = self { return true }
        return false
    }

    /// True when sync is suspended pending explicit user action (re-enter password, re-trust the
    /// server, or approve the host the login was redirected to). Used by the circuit breaker to
    /// stop retrying.
    var blocksSync: Bool {
        isAuthenticationRequired || isCertificateTrustRequired || isLoginHostApprovalRequired
    }
}
