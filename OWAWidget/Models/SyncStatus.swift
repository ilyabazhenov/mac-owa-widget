import Foundation

enum SyncStatus: Sendable {
    case idle
    case syncing
    case lastSynced(Date)
    case offlineCached(String)
    case error(String)
    /// Sync is suspended because the stored credentials were rejected by the server.
    /// Resumes automatically when the user updates their password.
    case authenticationRequired

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
}
