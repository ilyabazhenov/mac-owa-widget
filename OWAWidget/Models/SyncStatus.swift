import Foundation

enum SyncStatus: Sendable {
    case idle
    case syncing
    case lastSynced(Date)
    case error(String)

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
        case .error(let msg):
            return "Error: \(msg)"
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
}
